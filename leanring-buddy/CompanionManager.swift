//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns push-to-talk,
//  Codex realtime voice, computer-use, and overlay UI state.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState: Equatable {
    case idle
    case listening
    case processing
    case responding
}

enum CodexConnectionState: Equatable {
    case checking
    case needsSignIn
    case ready(planType: String?)
    case unavailable(message: String)
}

@MainActor
final class CompanionManager: ObservableObject {
    private static let defaultCodexModelID = "gpt-5.5"
    private static let defaultCodexReasoningEffort = "none"

    private static let computerUseDemoPrompt = """
    demo mode: keep all spoken output to a few short sentences total. first say one sentence explaining clicky: a macos menu bar companion with push-to-talk, screen context, and computer use to drive apps. then use computer use: if a web browser is frontmost, use it; otherwise open the default browser. open https://www.youtube.com/watch?v=dQw4w9WgXcQ and start playback (click play if needed). do not sign in, comment, change settings, or do anything beyond that url and playing the video. end with one short confirmation that it is playing.
    """

    @Published private(set) var voiceState: CompanionVoiceState = .idle
    /// Accumulated assistant text from Codex realtime transcript events while a voice turn is in flight.
    @Published private(set) var codexVoiceStreamingText: String = ""
    /// Strips trailing `[POINT:...]` from in-progress streamed text so the overlay does not flash raw tags.
    var codexVoiceStreamingPreviewForDisplay: String {
        let raw = codexVoiceStreamingText
        if let range = raw.range(of: "[POINT:", options: .literal) {
            return String(raw[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw
    }

    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var isAgentRunning = false

    /// Screen location (global AppKit coords) of a detected UI element the
    /// buddy should fly to and point at. Parsed from Codex's response;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?

    // MARK: - Onboarding Prompt Bubble

    /// Text streamed character-by-character on the cursor during onboarding.
    @Published var onboardingPromptText: String = ""
    @Published var onboardingPromptOpacity: Double = 0.0
    @Published var showOnboardingPrompt: Bool = false

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let realtimeVoiceManager = RealtimeVoiceManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let computerUseWindowContextController = CompanionComputerUseWindowContextController()

    private let codexAppServerClient = CodexAppServerClient.shared

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var realtimeVoiceManagerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var codexSignInPollingTask: Task<Void, Never>?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    private var browserAutomationPermissionStatusTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?
    private var macCursorIdleTimer: Timer?
    private var macCursorActivityMonitor: Any?

    /// True when required permissions are granted. Used by the menu to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission
            && hasScreenRecordingPermission
            && hasMicrophonePermission
            && hasScreenContentPermission
    }

    /// Whether the orange cursor overlay is currently visible on screen.
    /// Used by the menu to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Codex model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedCodexModel") ?? CompanionManager.defaultCodexModelID
    @Published var selectedReasoningEffort: String = UserDefaults.standard.string(forKey: "selectedCodexReasoningEffort") ?? CompanionManager.defaultCodexReasoningEffort
    @Published var isFastModeEnabled: Bool = UserDefaults.standard.object(forKey: "isCodexFastModeEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "isCodexFastModeEnabled")
    @Published private(set) var availableModels: [CodexModelOption] = []
    @Published private(set) var codexConnectionState: CodexConnectionState = .checking
    @Published private(set) var computerUseMCPStatus: CompanionComputerUseMCPStatus = .checking()
    @Published private(set) var browserAutomationPermissionStatus: CompanionBrowserAutomationPermissionStatus = .checking

    var speechOutputDisplayName: String {
        realtimeVoiceDisplayName
    }

    var isActiveCodingAgentReady: Bool {
        guard case .ready = codexConnectionState else {
            return false
        }
        return realtimeVoiceManager.isRealtimeAvailable
    }

    /// Menu-bar computer-use demo: does not require `isAgentRunning` so it stays available when the dashboard pauses push-to-talk.
    var isComputerUseDemoMenuEnabled: Bool {
        allPermissionsGranted && isActiveCodingAgentReady
    }

    var activeCodingAgentStatusLabel: String {
        switch codexConnectionState {
        case .checking:
            return "Checking"
        case .needsSignIn:
            return "Sign in"
        case .ready(let planType):
            if !realtimeVoiceManager.isRealtimeAvailable {
                return "Realtime \(realtimeVoiceManager.statusText)"
            }
            return planType?.isEmpty == false ? "Ready (\(planType!))" : "Ready"
        case .unavailable:
            return "Unavailable"
        }
    }

    var realtimeVoiceOptions: [CodexRealtimeVoiceOption] {
        realtimeVoiceManager.availableVoiceOptions
    }

    var selectedRealtimeVoice: String {
        realtimeVoiceManager.selectedVoiceID
    }

    var realtimeVoiceDisplayName: String {
        realtimeVoiceManager.selectedVoiceDisplayName
    }

    var realtimeVoiceStatusText: String {
        realtimeVoiceManager.statusText
    }

    var realtimeVoiceDetailText: String {
        realtimeVoiceManager.detailText
    }

    init() {
        realtimeVoiceManager.configure(
            captureScreens: {
                try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
            },
            pointAt: { [weak self] location, displayFrame, label in
                self?.setDetectedElementLocation(
                    location,
                    displayFrame: displayFrame,
                    bubbleText: label
                )
            },
            onAssistantTranscript: { [weak self] text in
                self?.codexVoiceStreamingText = text
            },
            onUserTranscript: { [weak self] transcript in
                self?.lastTranscript = transcript
            }
        )

        realtimeVoiceManagerCancellable = realtimeVoiceManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    func refreshCodingAgentConnectionState() {
        refreshCodexConnectionState()
    }

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedCodexModel")
        normalizeSelectedCodexModelSettings()

        if model == Self.defaultCodexModelID && selectedModelSupportsFastMode {
            setFastModeEnabled(true)
        }
    }

    func setSelectedReasoningEffort(_ reasoningEffort: String) {
        selectedReasoningEffort = reasoningEffort
        UserDefaults.standard.set(reasoningEffort, forKey: "selectedCodexReasoningEffort")
    }

    func setFastModeEnabled(_ enabled: Bool) {
        isFastModeEnabled = enabled && selectedModelSupportsFastMode
        UserDefaults.standard.set(isFastModeEnabled, forKey: "isCodexFastModeEnabled")
    }

    func setSelectedRealtimeVoice(_ voiceID: String) {
        realtimeVoiceManager.setSelectedVoiceID(voiceID)
    }

    func refreshRealtimeVoices() {
        realtimeVoiceManager.refreshAvailableVoices()
    }

    var selectedModelDisplayName: String {
        availableModels.first(where: { $0.id == selectedModel })?.displayName ?? (selectedModel.isEmpty ? "Default" : selectedModel)
    }

    var dashboardModelMetricLabel: String {
        selectedModelDisplayName
    }

    var selectedModelReasoningEfforts: [CodexReasoningEffortOption] {
        selectedModelOption?.supportedReasoningEfforts ?? []
    }

    var selectedModelSupportsFastMode: Bool {
        selectedModelOption?.supportsFastMode == true
    }

    var hasFastModeCompatibleModel: Bool {
        availableModels.contains(where: \.supportsFastMode)
    }

    private var selectedModelOption: CodexModelOption? {
        availableModels.first(where: { $0.id == selectedModel })
    }

    private var selectedReasoningEffortForCodexRequest: String? {
        selectedReasoningEffort.isEmpty ? selectedModelOption?.defaultReasoningEffort : selectedReasoningEffort
    }

    private var selectedServiceTierForCodexRequest: String? {
        isFastModeEnabled && selectedModelSupportsFastMode ? "fast" : nil
    }

    func refreshCodexConnectionState() {
        Task {
            do {
                let snapshot = try await codexAppServerClient.refreshSnapshot()
                await MainActor.run {
                    self.applyCodexSnapshot(snapshot)
                }
            } catch {
                await MainActor.run {
                    self.codexConnectionState = .unavailable(message: error.localizedDescription)
                }
            }
        }
    }

    func refreshComputerUseMCPStatus() {
        Task {
            let status = await codexAppServerClient.refreshComputerUseMCPStatus()
            await MainActor.run {
                self.computerUseMCPStatus = status
            }
        }
    }

    func refreshBrowserAutomationPermissionStatus() {
        browserAutomationPermissionStatusTask?.cancel()
        browserAutomationPermissionStatusTask = Task {
            let status = await CompanionBrowserAutomationPermissionManager.currentPermissionStatus()
            guard !Task.isCancelled else { return }
            browserAutomationPermissionStatus = status
        }
    }

    func requestBrowserAutomationPermission() {
        browserAutomationPermissionStatusTask?.cancel()
        browserAutomationPermissionStatus = .checking
        browserAutomationPermissionStatusTask = Task {
            let status = await CompanionBrowserAutomationPermissionManager.requestPermissionForPreferredRunningBrowser()
            guard !Task.isCancelled else { return }
            browserAutomationPermissionStatus = status
        }
    }

    func openBrowserAutomationPermissionHelper() {
        for browserTarget in CompanionBrowserAutomationTarget.supportedBrowsers {
            guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browserTarget.bundleIdentifier) else {
                continue
            }

            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration) { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.refreshBrowserAutomationPermissionStatus()
                }
            }
            return
        }

        if let automationSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(automationSettingsURL)
        }
    }

    func beginCodexSignIn() {
        codexSignInPollingTask?.cancel()

        Task {
            do {
                let authURL = try await codexAppServerClient.startChatGPTLogin()
                await MainActor.run {
                    self.codexConnectionState = .checking
                    NSWorkspace.shared.open(authURL)
                    self.pollForCompletedCodexSignIn()
                }
            } catch {
                await MainActor.run {
                    self.codexConnectionState = .unavailable(message: error.localizedDescription)
                }
            }
        }
    }

    private func pollForCompletedCodexSignIn() {
        codexSignInPollingTask = Task {
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }

                do {
                    let snapshot = try await codexAppServerClient.refreshSnapshot()
                    await MainActor.run {
                        self.applyCodexSnapshot(snapshot)
                    }

                    if snapshot.account.isSignedIn {
                        return
                    }
                } catch {
                    await MainActor.run {
                        self.codexConnectionState = .unavailable(message: error.localizedDescription)
                    }
                    return
                }
            }
        }
    }

    private func applyCodexSnapshot(_ snapshot: CodexAppServerSnapshot) {
        availableModels = snapshot.models

        let selectedModelIsAvailable = availableModels.contains(where: { $0.id == selectedModel })
        if let preferredDefaultModelID = Self.preferredDefaultModelID(from: availableModels),
           !selectedModelIsAvailable || selectedModel == snapshot.defaultModelID {
            setSelectedModel(preferredDefaultModelID)
        } else if let defaultModelID = snapshot.defaultModelID,
                  !selectedModelIsAvailable {
            setSelectedModel(defaultModelID)
        }

        normalizeSelectedCodexModelSettings()

        if snapshot.account.requiresOpenAIAuthentication && !snapshot.account.isSignedIn {
            codexConnectionState = .needsSignIn
            return
        }

        codexConnectionState = .ready(planType: snapshot.account.planType)
        refreshRealtimeVoices()
    }

    private func normalizeSelectedCodexModelSettings() {
        guard let selectedModelOption else { return }

        if shouldUseDefaultReasoningEffort(for: selectedModelOption) {
            let defaultReasoningEffort = Self.defaultReasoningEffort(for: selectedModelOption)
            selectedReasoningEffort = defaultReasoningEffort
            UserDefaults.standard.set(defaultReasoningEffort, forKey: "selectedCodexReasoningEffort")
        }

        if isFastModeEnabled && !selectedModelOption.supportsFastMode {
            isFastModeEnabled = false
            UserDefaults.standard.set(false, forKey: "isCodexFastModeEnabled")
        }
    }

    private func shouldUseDefaultReasoningEffort(for modelOption: CodexModelOption) -> Bool {
        if selectedReasoningEffort.isEmpty {
            return true
        }

        if !modelOption.supportedReasoningEfforts.contains(where: { $0.id == selectedReasoningEffort }) {
            return true
        }

        if let appServerDefaultReasoningEffort = modelOption.defaultReasoningEffort,
           selectedReasoningEffort == appServerDefaultReasoningEffort,
           appServerDefaultReasoningEffort != Self.defaultReasoningEffort(for: modelOption) {
            return true
        }

        return false
    }

    private static func preferredDefaultModelID(from modelOptions: [CodexModelOption]) -> String? {
        if let exactModelOption = modelOptions.first(where: { $0.id == defaultCodexModelID }) {
            return exactModelOption.id
        }

        return modelOptions.first { modelOption in
            modelOption.displayName
                .lowercased()
                .replacingOccurrences(of: " ", with: "-") == defaultCodexModelID
        }?.id
    }

    private static func defaultReasoningEffort(for modelOption: CodexModelOption) -> String {
        if modelOption.supportedReasoningEfforts.contains(where: { $0.id == defaultCodexReasoningEffort }) {
            return defaultCodexReasoningEffort
        }

        return modelOption.defaultReasoningEffort
            ?? modelOption.supportedReasoningEfforts.first?.id
            ?? ""
    }

    /// User preference for whether the Clicky cursor should stay visible.
    /// When toggled off, push-to-talk shows the overlay transiently for the interaction.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")
    @Published var shouldHideClickyWhenMacCursorIsIdle: Bool = UserDefaults.standard.bool(forKey: "shouldHideClickyWhenMacCursorIsIdle")
    @Published private(set) var isClickyHiddenBecauseMacCursorIsIdle = false

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        isClickyHiddenBecauseMacCursorIsIdle = false
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
            scheduleMacCursorIdleHideIfNeeded()
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    func setClickyHidesWhenMacCursorIsIdle(_ enabled: Bool) {
        shouldHideClickyWhenMacCursorIsIdle = enabled
        UserDefaults.standard.set(enabled, forKey: "shouldHideClickyWhenMacCursorIsIdle")

        if enabled {
            startMacCursorIdleTrackingIfNeeded()
            scheduleMacCursorIdleHideIfNeeded()
        } else {
            stopMacCursorIdleTracking()
            revealClickyHiddenByMacCursorIdle()
        }
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func setAgentRunning(_ enabled: Bool) {
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func start() {
        guard !isAgentRunning else { return }
        isAgentRunning = true
        refreshAllPermissions()
        print("Clicky start: accessibility=\(hasAccessibilityPermission), screen=\(hasScreenRecordingPermission), mic=\(hasMicrophonePermission), screenContent=\(hasScreenContentPermission), onboarded=\(hasCompletedOnboarding)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        // Warm up the selected coding agent bridge early so login/model state is ready
        // before the user first tries to talk to Clicky.
        refreshCodingAgentConnectionState()
        refreshComputerUseMCPStatus()
        refreshBrowserAutomationPermissionStatus()
        refreshRealtimeVoices()
        startMacCursorIdleTrackingIfNeeded()

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // menu will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
            scheduleMacCursorIdleHideIfNeeded()
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the menu and restarts
    /// the overlay so the welcome animation and onboarding prompt play.
    func triggerOnboarding() {
        // Post notification so the menu manager can dismiss the menu
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        // Play onboarding music at 60% volume, fade out after 1m 30s
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and onboarding prompt
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
        scheduleMacCursorIdleHideIfNeeded()
    }

    /// Replays the onboarding experience from the "Watch Onboarding Again"
    /// footer link. Same flow as triggerOnboarding but the cursor overlay
    /// is already visible so we just restart the welcome animation and prompt.
    func replayOnboarding() {
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
        scheduleMacCursorIdleHideIfNeeded()
    }

    private func stopOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil
        onboardingMusicPlayer?.stop()
        onboardingMusicPlayer = nil
    }

    private func startOnboardingMusic() {
        stopOnboardingMusic()
        guard let musicURL = Bundle.main.url(forResource: "ff", withExtension: "mp3") else {
            print("Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // After 1m 30s, fade the music out over 3s
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        guard let player = onboardingMusicPlayer else { return }

        let fadeSteps = 30
        let fadeDuration: Double = 3.0
        let stepInterval = fadeDuration / Double(fadeSteps)
        let volumeDecrement = player.volume / Float(fadeSteps)
        var stepsRemaining = fadeSteps

        onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] timer in
            stepsRemaining -= 1
            player.volume -= volumeDecrement

            if stepsRemaining <= 0 {
                timer.invalidate()
                player.stop()
                self?.onboardingMusicPlayer = nil
                self?.onboardingMusicFadeTimer = nil
            }
        }
    }

    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        scheduleMacCursorIdleHideIfNeeded()
    }

    private func setDetectedElementLocation(
        _ location: CGPoint,
        displayFrame: CGRect,
        bubbleText: String?
    ) {
        detectedElementScreenLocation = location
        detectedElementDisplayFrame = displayFrame
        detectedElementBubbleText = bubbleText
        print("Element pointing: x=\(Int(location.x)), y=\(Int(location.y)), label=\(bubbleText ?? "element")")
    }

    func stop() {
        guard isAgentRunning else { return }
        isAgentRunning = false
        globalPushToTalkShortcutMonitor.stop()
        realtimeVoiceManager.cancelCurrentSession(stopRemote: true)
        overlayWindowManager.hideOverlay()
        isOverlayVisible = false
        isClickyHiddenBecauseMacCursorIsIdle = false
        transientHideTask?.cancel()
        stopMacCursorIdleTracking()

        codexSignInPollingTask?.cancel()
        codexSignInPollingTask = nil
        browserAutomationPermissionStatusTask?.cancel()
        browserAutomationPermissionStatusTask = nil
        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("Permissions: accessibility=\(hasAccessibilityPermission), screen=\(hasScreenRecordingPermission), mic=\(hasMicrophonePermission), screenContent=\(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
        }
        // Screen content permission is persisted once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        refreshBrowserAutomationPermissionStatus()

        if !previouslyHadAll && allPermissionsGranted {
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're never asked again during onboarding.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content. A 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("Screen content capture: width=\(image.width), height=\(image.height), didCapture=\(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")

                    // If onboarding was already completed, show the cursor overlay now
                    if hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                        scheduleMacCursorIdleHideIfNeeded()
                    }
                }
            } catch {
                print("Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = realtimeVoiceManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = realtimeVoiceManager.$voiceState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] voiceState in
                guard let self else { return }
                self.voiceState = voiceState

                if voiceState == .idle {
                    self.scheduleTransientHideIfNeeded()
                    self.scheduleMacCursorIdleHideIfNeeded()
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            guard !realtimeVoiceManager.isVoiceInputActive else { return }
            print("Companion push-to-talk: start requested")

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil
            macCursorIdleTimer?.invalidate()
            macCursorIdleTimer = nil
            revealClickyHiddenByMacCursorIdle()

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isClickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar menu so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Interrupt any in-progress realtime output so the new spoken turn starts cleanly.
            realtimeVoiceManager.cancelCurrentSession(stopRemote: true)
            clearDetectedElementLocation()
            codexVoiceStreamingText = ""

            // Dismiss the onboarding prompt if it's showing
            if showOnboardingPrompt {
                withAnimation(.easeOut(duration: 0.3)) {
                    onboardingPromptOpacity = 0.0
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    self.showOnboardingPrompt = false
                    self.onboardingPromptText = ""
                }
            }
    

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await realtimeVoiceManager.startVoiceInput(
                    model: selectedModel,
                    serviceTier: selectedServiceTierForCodexRequest,
                    systemPrompt: Self.companionVoiceResponseSystemPrompt
                )
            }
        case .released:
            print("Companion push-to-talk: stop requested")
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            if !realtimeVoiceManager.isVoiceInputActive {
                pendingKeyboardShortcutStartTask?.cancel()
                pendingKeyboardShortcutStartTask = nil
            }
            realtimeVoiceManager.stopVoiceInput()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user is talking to you through Codex realtime audio. your reply will be spoken aloud, so write the way you'd actually talk. this is an ongoing conversation and you remember the thread.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, call clicky.get_current_screen before answering and reference specific things you see.
    - if the screen is not relevant to their question, answer directly without asking for screen context.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    computer use:
    - when the user explicitly asks you to control an app, control a browser, or run a demo, use the available computer-use tools as needed. you may use multiple computer-use steps in one turn to finish launching or focusing an app.
    - when the user combines opening or switching an app with a follow-up question that depends on the new UI (where to type, what to click, etc.), finish launching or focusing first, then call clicky.get_current_screen before answering.
    - after any app, window, or browser action, call clicky.get_current_screen before answering screen-location questions. do this in the same spoken turn.
    - when you use computer-use tools: perform the actions without narrating. no play-by-play, no screen tour, no recap list of steps.
    - after purely mechanical tools finish, spoken output is at most one short phrase confirming the outcome (about ten words or fewer), unless the user explicitly asked for explanation, teaching, or a walkthrough.
    - for purely mechanical requests (open an app, click something, run a demo, go to a url) with no follow-up question about the new UI, do not add extra tips, related ideas, or seed-planting — those rules apply to conversational answers, not to computer-use execution turns.
    - keep actions reversible and harmless. don't submit forms, send messages, buy anything, delete anything, or change account/settings data.
    - if a browser action is requested and no browser is visible, open the default browser with computer use if possible, then continue the browser action.

    element pointing:
    you have a small orange cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, use clicky.point_at with screenshot pixel coordinates from the latest clicky.get_current_screen result. the origin is the top-left corner of the screenshot image. x increases rightward, y increases downward. include screenNumber when pointing at a screen other than the primary focus screen.

    do not use textual point tags as your primary pointing mechanism. use clicky.point_at.
    """

    // MARK: - AI Response Pipeline

    func submitTypedPrompt(_ prompt: String) {
        Task {
            await realtimeVoiceManager.submitTextPrompt(
                prompt,
                model: selectedModel,
                serviceTier: selectedServiceTierForCodexRequest,
                systemPrompt: Self.companionVoiceResponseSystemPrompt
            )
        }
    }

    func runComputerUseDemo() {
        ClickyMessageLogStore.shared.append(
            lane: "menu",
            direction: "outgoing",
            event: "computer_use_demo.started"
        )
        submitTypedPrompt(Self.computerUseDemoPrompt)
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for realtime output and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for realtime voice playback to finish.
            while voiceState != .idle {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    private func startMacCursorIdleTrackingIfNeeded() {
        guard shouldHideClickyWhenMacCursorIsIdle else { return }
        guard macCursorActivityMonitor == nil else { return }

        macCursorActivityMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleMacCursorActivity()
            }
        }
    }

    private func stopMacCursorIdleTracking() {
        macCursorIdleTimer?.invalidate()
        macCursorIdleTimer = nil

        if let macCursorActivityMonitor {
            NSEvent.removeMonitor(macCursorActivityMonitor)
            self.macCursorActivityMonitor = nil
        }
    }

    private func handleMacCursorActivity() {
        revealClickyHiddenByMacCursorIdle()
        scheduleMacCursorIdleHideIfNeeded()
    }

    private func scheduleMacCursorIdleHideIfNeeded() {
        macCursorIdleTimer?.invalidate()
        macCursorIdleTimer = nil

        guard isAgentRunning else { return }
        guard shouldHideClickyWhenMacCursorIsIdle else { return }
        guard isClickyCursorEnabled else { return }

        macCursorIdleTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.hideClickyForMacCursorIdleIfNeeded()
            }
        }
    }

    private func hideClickyForMacCursorIdleIfNeeded() {
        guard isAgentRunning else { return }
        guard shouldHideClickyWhenMacCursorIsIdle else { return }
        guard isClickyCursorEnabled else { return }
        guard isOverlayVisible else { return }
        guard voiceState == .idle else {
            scheduleMacCursorIdleHideIfNeeded()
            return
        }
        guard detectedElementScreenLocation == nil else {
            scheduleMacCursorIdleHideIfNeeded()
            return
        }

        overlayWindowManager.fadeOutAndHideOverlay()
        isOverlayVisible = false
        isClickyHiddenBecauseMacCursorIsIdle = true
    }

    private func revealClickyHiddenByMacCursorIdle() {
        guard isClickyHiddenBecauseMacCursorIsIdle else { return }

        isClickyHiddenBecauseMacCursorIsIdle = false

        guard isAgentRunning && isClickyCursorEnabled && hasCompletedOnboarding && allPermissionsGranted else { return }

        overlayWindowManager.hasShownOverlayBefore = true
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Codex's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Codex said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Codex's response.
    /// Returns the text with the tag removed and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

    // MARK: - Onboarding Prompt

    func startOnboardingPromptStream() {
        let message = "press control + option and introduce yourself"
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                // Auto-dismiss after 10 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
                    guard self.showOnboardingPrompt else { return }
                    withAnimation(.easeOut(duration: 0.3)) {
                        self.onboardingPromptOpacity = 0.0
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        self.showOnboardingPrompt = false
                        self.onboardingPromptText = ""
                    }
                }
                return
            }
            let index = message.index(message.startIndex, offsetBy: currentIndex)
            self.onboardingPromptText.append(message[index])
            currentIndex += 1
        }
    }
}
