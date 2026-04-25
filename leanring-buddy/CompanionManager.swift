//
//  CompanionManager.swift
//  leanring-buddy
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Speech
import SwiftUI

enum CompanionVoiceState {
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

private enum CompanionResponseInputSource {
    case typedPrompt
    case voiceTranscript

    var logName: String {
        switch self {
        case .typedPrompt:
            return "typed input"
        case .voiceTranscript:
            return "voice input"
        }
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    private static let macCursorIdleHideDelaySeconds: CFTimeInterval = 3.0
    private static let macCursorIdleTrackingIntervalSeconds: TimeInterval = 0.12
    private static let macCursorMovementEventTypes: [CGEventType] = [
        .mouseMoved,
        .leftMouseDragged,
        .rightMouseDragged,
        .otherMouseDragged
    ]

    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasSpeechRecognitionPermission = false
    @Published private(set) var hasScreenContentPermission = false
    @Published private(set) var browserAutomationPermissionStatus: CompanionBrowserAutomationPermissionStatus = .checking

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
    private var onboardingPromptStreamTimer: Timer?

    // MARK: - Onboarding Music

    private var onboardingMusicPlayer: AVAudioPlayer?
    private var onboardingMusicFadeTimer: Timer?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let computerUseWindowContextController = CompanionComputerUseWindowContextController()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    private lazy var codexAppServerClient: CodexAppServerClient = {
        return CodexAppServerClient()
    }()
    private var nativeSpeechSynthesizer: NSSpeechSynthesizer?

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?
    private var macCursorIdleTrackingTimer: Timer?
    private var codexSignInPollingTask: Task<Void, Never>?
    private var hasStartedAgentPipeline = false

    /// True when the permissions required to launch Clicky's cursor experience are granted.
    /// Speech Recognition and Browser Automation are still checked and shown in the UI,
    /// but they should not hide the overlay cursor if unavailable or revoked.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission
            && hasScreenRecordingPermission
            && hasMicrophonePermission
            && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// The Codex model used for voice responses. Persisted to UserDefaults.
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: "selectedCodexModel") ?? ""
    @Published var selectedReasoningEffort: String = UserDefaults.standard.string(forKey: "selectedCodexReasoningEffort") ?? ""
    @Published var isFastModeEnabled: Bool = UserDefaults.standard.bool(forKey: "isCodexFastModeEnabled")
    @Published private(set) var availableModels: [CodexModelOption] = []
    @Published private(set) var codexConnectionState: CodexConnectionState = .checking

    /// Master preference for whether Clicky's agent pipeline is running.
    /// When disabled, Clicky keeps the menu bar UI available but stops
    /// listening, responding, speaking, and showing the overlay.
    @Published var isAgentRunning: Bool = UserDefaults.standard.object(forKey: "isAgentRunning") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isAgentRunning")

    func setAgentRunning(_ enabled: Bool) {
        guard isAgentRunning != enabled else { return }

        isAgentRunning = enabled
        UserDefaults.standard.set(enabled, forKey: "isAgentRunning")

        if enabled {
            start()
        } else {
            stop()
        }
    }

    func setSelectedModel(_ model: String) {
        selectedModel = model
        UserDefaults.standard.set(model, forKey: "selectedCodexModel")
        normalizeSelectedCodexModelSettings()
    }

    func setSelectedReasoningEffort(_ reasoningEffort: String) {
        selectedReasoningEffort = reasoningEffort
        UserDefaults.standard.set(reasoningEffort, forKey: "selectedCodexReasoningEffort")
    }

    func setFastModeEnabled(_ enabled: Bool) {
        isFastModeEnabled = enabled && selectedModelSupportsFastMode
        UserDefaults.standard.set(isFastModeEnabled, forKey: "isCodexFastModeEnabled")
    }

    var speechOutputDisplayName: String {
        "macOS Speech"
    }

    var selectedModelDisplayName: String {
        availableModels.first(where: { $0.id == selectedModel })?.displayName ?? (selectedModel.isEmpty ? "Default" : selectedModel)
    }

    var selectedModelReasoningEfforts: [CodexReasoningEffortOption] {
        selectedModelOption?.supportedReasoningEfforts ?? []
    }

    var selectedReasoningEffortDisplayName: String {
        selectedModelReasoningEfforts.first(where: { $0.id == selectedReasoningEffort })?.displayName ?? selectedReasoningEffort
    }

    var selectedModelSupportsFastMode: Bool {
        selectedModelOption?.supportsFastMode == true
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

    private static func formattedResponseLogDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return "\(Int((duration * 1_000).rounded()))ms"
        }

        return String(format: "%.2fs", duration)
    }

    private func printResponseTiming(
        source: CompanionResponseInputSource,
        _ message: String,
        since startDate: Date? = nil
    ) {
        if let startDate {
            let elapsedDuration = Date().timeIntervalSince(startDate)
            print("Timing: Clicky \(source.logName) +\(Self.formattedResponseLogDuration(elapsedDuration)): \(message)")
        } else {
            print("Timing: Clicky \(source.logName): \(message)")
        }
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

    func beginCodexSignIn() {
        codexSignInPollingTask?.cancel()

        Task {
            do {
                let authURL = try await codexAppServerClient.startChatGPTLogin()
                await MainActor.run {
                    self.codexConnectionState = .checking
                    NSWorkspace.shared.open(authURL)
                }
                await self.pollForCompletedCodexSignIn()
            } catch {
                await MainActor.run {
                    self.codexConnectionState = .unavailable(message: error.localizedDescription)
                }
            }
        }
    }

    private func pollForCompletedCodexSignIn() async {
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

        if let defaultModelID = snapshot.defaultModelID,
           !availableModels.contains(where: { $0.id == selectedModel }) {
            setSelectedModel(defaultModelID)
        }

        normalizeSelectedCodexModelSettings()

        if snapshot.account.requiresOpenAIAuthentication && !snapshot.account.isSignedIn {
            codexConnectionState = .needsSignIn
            return
        }

        codexConnectionState = .ready(planType: snapshot.account.planType)
    }

    private func normalizeSelectedCodexModelSettings() {
        guard let selectedModelOption else { return }

        if !selectedModelOption.supportedReasoningEfforts.contains(where: { $0.id == selectedReasoningEffort }) {
            let defaultReasoningEffort = selectedModelOption.defaultReasoningEffort
                ?? selectedModelOption.supportedReasoningEfforts.first?.id
                ?? ""
            selectedReasoningEffort = defaultReasoningEffort
            UserDefaults.standard.set(defaultReasoningEffort, forKey: "selectedCodexReasoningEffort")
        }

        if isFastModeEnabled && !selectedModelOption.supportsFastMode {
            isFastModeEnabled = false
            UserDefaults.standard.set(false, forKey: "isCodexFastModeEnabled")
        }
    }

    /// User preference for whether the Clicky cursor should stay visible.
    /// When toggled off, push-to-talk shows the overlay transiently for the interaction.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isClickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isClickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isClickyCursorEnabled")

    /// Mirrors macOS-style cursor idle behavior by fading Clicky after the
    /// mouse stops moving, then revealing it again on movement.
    @Published var shouldHideClickyWhenMacCursorIsIdle: Bool = UserDefaults.standard.object(forKey: "shouldHideClickyWhenMacCursorIsIdle") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "shouldHideClickyWhenMacCursorIsIdle")
    @Published private(set) var isClickyHiddenBecauseMacCursorIsIdle = false

    func setClickyHidesWhenMacCursorIsIdle(_ enabled: Bool) {
        shouldHideClickyWhenMacCursorIsIdle = enabled
        UserDefaults.standard.set(enabled, forKey: "shouldHideClickyWhenMacCursorIsIdle")

        if enabled {
            isClickyHiddenBecauseMacCursorIsIdle = false
            startMacCursorIdleTrackingIfNeeded()
        } else {
            stopMacCursorIdleTracking()
        }
    }

    func setClickyCursorEnabled(_ enabled: Bool) {
        isClickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isClickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled && isAgentRunning {
            isClickyHiddenBecauseMacCursorIsIdle = false
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    func submitTypedPrompt(_ prompt: String) {
        guard isAgentRunning else { return }

        let promptSubmittedAt = Date()
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        lastTranscript = trimmedPrompt
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        isClickyHiddenBecauseMacCursorIsIdle = false

        if !isOverlayVisible {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }

        sendTranscriptToCodexWithScreenshot(
            transcript: trimmedPrompt,
            source: .typedPrompt,
            inputReceivedAt: promptSubmittedAt
        )
    }

    /// Whether the user has completed onboarding at least once. Persisted
    /// to UserDefaults so the Start button only appears on first launch.
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "hasCompletedOnboarding") }
    }

    func start() {
        guard isAgentRunning else {
            refreshAllPermissions()
            stopAgentActivity()
            return
        }
        guard !hasStartedAgentPipeline else { return }

        hasStartedAgentPipeline = true
        refreshAllPermissions()
        computerUseWindowContextController.refresh(screenContentGranted: hasScreenContentPermission)
        printStartupState()
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindShortcutTransitions()
        startMacCursorIdleTrackingIfNeeded()
        // Warm up the local Codex bridge early so login/model state is ready
        // before the user first tries to talk to Clicky.
        refreshCodexConnectionState()

        // If the user already completed onboarding AND all permissions are
        // still granted, show the cursor overlay immediately. If permissions
        // were revoked (e.g. signing change), don't show the cursor — the
        // panel will show the permissions UI instead.
        if hasCompletedOnboarding && allPermissionsGranted && isClickyCursorEnabled {
            overlayWindowManager.hasShownOverlayBefore = true
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    private func printStartupState() {
        print("Startup state")
        print("   Accessibility: \(permissionStatusText(hasAccessibilityPermission))")
        print("   Screen Recording: \(permissionStatusText(hasScreenRecordingPermission))")
        print("   Microphone: \(permissionStatusText(hasMicrophonePermission))")
        print("   Speech Recognition: \(permissionStatusText(hasSpeechRecognitionPermission))")
        print("   Screen Content: \(permissionStatusText(hasScreenContentPermission))")
        print("   Browser Automation: \(browserAutomationPermissionStatus.statusText)")
        print("   Onboarding: \(hasCompletedOnboarding ? "completed" : "not completed")")
    }

    private func permissionStatusText(_ isGranted: Bool) -> String {
        isGranted ? "granted" : "missing"
    }

    func requestBrowserAutomationPermission() {
        browserAutomationPermissionStatus = .checking
        Task {
            let permissionStatus = await CompanionBrowserAutomationPermissionManager.requestPermissionForPreferredRunningBrowser()
            browserAutomationPermissionStatus = permissionStatus

            if !permissionStatus.isGranted {
                PermisoAssistant.shared.present(
                    panel: .automation(targetApplicationName: permissionStatus.browserName)
                )
            }
        }
    }

    func openBrowserAutomationPermissionHelper() {
        PermisoAssistant.shared.present(
            panel: .automation(targetApplicationName: browserAutomationPermissionStatus.browserName)
        )
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    /// Triggers the onboarding sequence — dismisses the panel and restarts
    /// the overlay so the welcome animation and screen-aware intro play.
    func triggerOnboarding() {
        guard isAgentRunning else { return }

        // Post notification so the panel manager can dismiss the panel
        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

        // Mark onboarding as completed so the Start button won't appear
        // again on future launches — the cursor will auto-show instead
        hasCompletedOnboarding = true

        resetOnboardingPrompt()
        isClickyHiddenBecauseMacCursorIsIdle = false

        // Play Besaid theme while the welcome animation and screen-aware prompt run.
        startOnboardingMusic()

        // Show the overlay for the first time — isFirstAppearance triggers
        // the welcome animation and screen-aware onboarding prompt
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
    }

    /// Replays the onboarding experience from the footer link. Same flow as
    /// triggerOnboarding but the cursor overlay is already visible so we just
    /// restart the welcome animation and screen-aware prompt.
    func replayOnboarding() {
        guard isAgentRunning else { return }

        NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)
        resetOnboardingPrompt()
        isClickyHiddenBecauseMacCursorIsIdle = false
        startOnboardingMusic()
        // Tear down any existing overlays and recreate with isFirstAppearance = true
        overlayWindowManager.hasShownOverlayBefore = false
        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        isOverlayVisible = true
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
            print("Warning: Clicky: ff.mp3 not found in bundle")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: musicURL)
            player.volume = 0.3
            player.play()
            self.onboardingMusicPlayer = player

            // Safety fallback in case onboarding prompt generation never completes.
            onboardingMusicFadeTimer = Timer.scheduledTimer(withTimeInterval: 90.0, repeats: false) { [weak self] _ in
                self?.fadeOutOnboardingMusic()
            }
        } catch {
            print("Warning: Clicky: Failed to play onboarding music: \(error)")
        }
    }

    private func fadeOutOnboardingMusic() {
        onboardingMusicFadeTimer?.invalidate()
        onboardingMusicFadeTimer = nil

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
    }

    func stop() {
        hasStartedAgentPipeline = false
        stopAgentActivity()
    }

    private func stopAgentActivity() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()
        transientHideTask = nil
        stopMacCursorIdleTracking()
        pendingKeyboardShortcutStartTask?.cancel()
        pendingKeyboardShortcutStartTask = nil

        currentResponseTask?.cancel()
        currentResponseTask = nil
        codexSignInPollingTask?.cancel()
        codexSignInPollingTask = nil
        shortcutTransitionCancellable?.cancel()
        shortcutTransitionCancellable = nil
        voiceStateCancellable?.cancel()
        voiceStateCancellable = nil
        audioPowerCancellable?.cancel()
        audioPowerCancellable = nil
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
        stopNativeSpeechPlayback()
        stopOnboardingMusic()
        clearDetectedElementLocation()
        resetOnboardingPrompt()
        currentAudioPowerLevel = 0
        voiceState = .idle
        isOverlayVisible = false
    }

    func refreshAllPermissions() {
        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility && isAgentRunning {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        let speechRecognitionAuthorizationStatus = SFSpeechRecognizer.authorizationStatus()
        hasSpeechRecognitionPermission = speechRecognitionAuthorizationStatus == .authorized

        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        refreshBrowserAutomationPermissionStatus()
    }

    private func refreshBrowserAutomationPermissionStatus() {
        Task {
            browserAutomationPermissionStatus = await CompanionBrowserAutomationPermissionManager.currentPermissionStatus()
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
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    computerUseWindowContextController.refresh(screenContentGranted: hasScreenContentPermission)

                    // If onboarding was already completed, show the cursor overlay now
                    if isAgentRunning && hasCompletedOnboarding && allPermissionsGranted && !isOverlayVisible && isClickyCursorEnabled {
                        overlayWindowManager.hasShownOverlayBefore = true
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("Warning: Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func startMacCursorIdleTrackingIfNeeded() {
        macCursorIdleTrackingTimer?.invalidate()
        macCursorIdleTrackingTimer = nil

        guard isAgentRunning && shouldHideClickyWhenMacCursorIsIdle else {
            isClickyHiddenBecauseMacCursorIsIdle = false
            return
        }

        macCursorIdleTrackingTimer = Timer.scheduledTimer(withTimeInterval: Self.macCursorIdleTrackingIntervalSeconds, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshClickyVisibilityForMacCursorIdle()
            }
        }
    }

    private func stopMacCursorIdleTracking() {
        macCursorIdleTrackingTimer?.invalidate()
        macCursorIdleTrackingTimer = nil
        isClickyHiddenBecauseMacCursorIsIdle = false
    }

    private func refreshClickyVisibilityForMacCursorIdle() {
        guard shouldHideClickyWhenMacCursorIsIdle && isAgentRunning else {
            isClickyHiddenBecauseMacCursorIsIdle = false
            return
        }

        let secondsSinceLastCursorMovement = Self.macCursorMovementEventTypes
            .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
            .min() ?? 0
        let shouldHideBecauseCursorIsIdle = secondsSinceLastCursorMovement >= Self.macCursorIdleHideDelaySeconds
            && canHideClickyForMacCursorIdle

        guard isClickyHiddenBecauseMacCursorIsIdle != shouldHideBecauseCursorIsIdle else { return }
        isClickyHiddenBecauseMacCursorIsIdle = shouldHideBecauseCursorIsIdle
    }

    private var canHideClickyForMacCursorIdle: Bool {
        voiceState == .idle
            && !(nativeSpeechSynthesizer?.isSpeaking ?? false)
            && detectedElementScreenLocation == nil
            && pendingKeyboardShortcutStartTask == nil
            && !buddyDictationManager.isDictationInProgress
            && !showOnboardingPrompt
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable?.cancel()
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable?.cancel()
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording, isFinalizing, isPreparing in
                guard let self else { return }
                // Don't override .responding — the AI response pipeline
                // manages that state directly until streaming finishes.
                guard self.voiceState != .responding else { return }

                if isFinalizing {
                    self.voiceState = .processing
                } else if isRecording {
                    self.voiceState = .listening
                } else if isPreparing {
                    self.voiceState = .processing
                } else {
                    self.voiceState = .idle
                    // If the user pressed and released the hotkey without
                    // saying anything, no response task runs — schedule the
                    // transient hide here so the overlay doesn't get stuck.
                    // Only do this when no response is in flight, otherwise
                    // the brief idle gap between recording and processing
                    // would prematurely hide the overlay.
                    if self.currentResponseTask == nil {
                        self.scheduleTransientHideIfNeeded()
                    }
                }
            }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable?.cancel()
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
            guard isAgentRunning else { return }
            guard !buddyDictationManager.isDictationInProgress else { return }

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil
            isClickyHiddenBecauseMacCursorIsIdle = false

            // If the cursor overlay is hidden, bring it up for this keyboard interaction.
            // When Show Clicky is off, the transient-hide path will dismiss it after the response.
            if !isOverlayVisible {
                overlayWindowManager.hasShownOverlayBefore = true
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .clickyDismissPanel, object: nil)

            // Cancel any in-progress response and speech from a previous utterance
            currentResponseTask?.cancel()
            stopNativeSpeechPlayback()
            clearDetectedElementLocation()

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
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut { [weak self] finalTranscript in
                    self?.lastTranscript = finalTranscript
                    print("Companion received transcript: \(finalTranscript)")
                    self?.sendTranscriptToCodexWithScreenshot(
                        transcript: finalTranscript,
                        source: .voiceTranscript,
                        inputReceivedAt: Date()
                    )
                }
            }
        case .released:
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
        case .none:
            break
        }
    }

    // MARK: - Companion Prompt

    private static let companionVoiceResponseSystemPrompt = """
    you're clicky, a friendly always-on companion that lives in the user's menu bar. the user just spoke to you via push-to-talk and you can see their screen(s). your reply will be spoken aloud via text-to-speech, so write the way you'd actually talk. this is an ongoing conversation — you remember everything they've said before.

    rules:
    - default to one or two sentences. be direct and dense. BUT if the user asks you to explain more, go deeper, or elaborate, then go all out — give a thorough, detailed explanation with no length limit.
    - all lowercase, casual, warm. no emojis.
    - write for the ear, not the eye. short sentences. no lists, bullet points, markdown, or formatting — just natural speech.
    - don't use abbreviations or symbols that sound weird read aloud. write "for example" not "e.g.", spell out small numbers.
    - if the user's question relates to what's on their screen, reference specific things you see.
    - if the screenshot doesn't seem relevant to their question, just answer the question directly.
    - you can help with anything — coding, writing, general knowledge, brainstorming.
    - never say "simply" or "just".
    - don't read out code verbatim. describe what the code does or what needs to change conversationally.
    - focus on giving a thorough, useful explanation. don't end with simple yes/no questions like "want me to explain more?" or "should i show you?" — those are dead ends that force the user to just say yes.
    - instead, when it fits naturally, end by planting a seed — mention something bigger or more ambitious they could try, a related concept that goes deeper, or a next-level technique that builds on what you just explained. make it something worth coming back for, not a question they'd just nod to. it's okay to not end with anything extra if the answer is complete on its own.
    - if you receive multiple screen images, the one labeled "primary focus" is where the cursor is — prioritize that one but reference others if relevant.

    element pointing:
    you have a small blue triangle cursor that can fly to and point at things on screen. use it whenever pointing would genuinely help the user — if they're asking how to do something, looking for a menu, trying to find a button, or need help navigating an app, point at the relevant element. err on the side of pointing rather than not pointing, because it makes your help way more useful and concrete.

    don't point at things when it would be pointless — like if the user asks a general knowledge question, or the conversation has nothing to do with what's on screen, or you'd just be pointing at something obvious they're already looking at. but if there's a specific UI element, menu, button, or area on screen that's relevant to what you're helping with, point at it.

    when you point, append a coordinate tag at the very end of your response, AFTER your spoken text. the screenshot images are labeled with their pixel dimensions. use those dimensions as the coordinate space. the origin (0,0) is the top-left corner of the image. x increases rightward, y increases downward.

    format: [POINT:x,y:label] where x,y are integer pixel coordinates in the screenshot's coordinate space, and label is a short 1-3 word description of the element (like "search bar" or "save button"). if the element is on the cursor's screen you can omit the screen number. if the element is on a DIFFERENT screen, append :screenN where N is the screen number from the image label (e.g. :screen2). this is important — without the screen number, the cursor will point at the wrong place.

    if pointing wouldn't help, append [POINT:none].

    examples:
    - user asks how to color grade in final cut: "you'll want to open the color inspector — it's right up in the top right area of the toolbar. click that and you'll get all the color wheels and curves. [POINT:1100,42:color inspector]"
    - user asks what html is: "html stands for hypertext markup language, it's basically the skeleton of every web page. curious how it connects to the css you're looking at? [POINT:none]"
    - user asks how to commit in xcode: "see that source control menu up top? click that and hit commit, or you can use command option c as a shortcut. [POINT:285,11:source control]"
    - element is on screen 2 (not where cursor is): "that's over on your other monitor — see the terminal window? [POINT:400,300:terminal:screen2]"
    """

    private static let backgroundActionPlannerSystemPrompt = """
    you're clicky's background computer-use planner. decide whether the user's message is asking clicky to quietly perform a safe background action without asking a follow-up.

    return json only. no markdown. no commentary.

    supported actions:
    - open_url_in_background_browser: opens a public http or https url in an already-running browser window without intentionally foregrounding the browser.
    - press_ax_target: presses one listed accessibility target ref, like @e1.
    - focus_ax_target: focuses one listed accessibility target ref.
    - set_ax_text: replaces the text value of one listed accessibility target ref.
    - scroll_ax_target: scrolls one listed accessibility target ref. use positive scrollY to scroll down, negative scrollY to scroll up.
    - perform_ax_action: performs one safe listed accessibility action. axAction may be press, increment, decrement, confirm, cancel, show_menu, or pick.
    - wait: waits briefly between actions when the next action needs the app to settle.

    rules:
    - if the user clearly asks you to do something in the background or asks clicky to operate the current app, create actions. do not ask for confirmation.
    - only use accessibility refs that appear in the provided current controlled window context.
    - prefer set_ax_text for replacing text fields, press_ax_target for buttons/links/menu items, scroll_ax_target for scroll areas, and perform_ax_action only when a more specific action type does not fit.
    - keep plans short: one to six actions unless the user explicitly asks for a multi-step operation.
    - do not use background computer actions for destructive, irreversible, purchasing, sending, deleting, or security-sensitive operations. return an empty actions array for those.
    - if the user asks a question, asks for advice, needs explanation, needs screen-specific guidance, or the request is not clearly executable with the supported actions, return an empty actions array.
    - choose reusable web urls, not special clicky commands. for media, documents, search, or web content, choose a normal public url that best satisfies the request.
    - do not invent private or local urls.
    - spokenText should be a short natural sentence clicky can say after the action runs. leave it empty when actions is empty.
    """

    private static let backgroundActionOutputSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": ["spokenText", "actions"],
        "properties": [
            "spokenText": [
                "type": "string"
            ],
            "actions": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": [
                        "type",
                        "url",
                        "ref",
                        "text",
                        "scrollX",
                        "scrollY",
                        "steps",
                        "axAction",
                        "milliseconds"
                    ],
                    "properties": [
                        "type": [
                            "type": "string",
                            "enum": [
                                "open_url_in_background_browser",
                                "press_ax_target",
                                "focus_ax_target",
                                "set_ax_text",
                                "scroll_ax_target",
                                "perform_ax_action",
                                "wait"
                            ]
                        ],
                        "url": [
                            "type": ["string", "null"]
                        ],
                        "ref": [
                            "type": ["string", "null"]
                        ],
                        "text": [
                            "type": ["string", "null"]
                        ],
                        "scrollX": [
                            "type": ["integer", "null"]
                        ],
                        "scrollY": [
                            "type": ["integer", "null"]
                        ],
                        "steps": [
                            "type": ["integer", "null"]
                        ],
                        "axAction": [
                            "type": ["string", "null"],
                            "enum": ["press", "increment", "decrement", "confirm", "cancel", "show_menu", "pick", NSNull()]
                        ],
                        "milliseconds": [
                            "type": ["integer", "null"]
                        ]
                    ]
                ]
            ]
        ]
    ]

    // MARK: - AI Response Pipeline

    /// Captures a screenshot, sends it along with the transcript to Codex,
    /// and plays the response aloud. The cursor stays in
    /// the spinner/processing state until speech playback begins.
    /// Codex's response may include a [POINT:x,y:label] tag which triggers
    /// the buddy to fly to that element on screen.
    private func sendTranscriptToCodexWithScreenshot(
        transcript: String,
        source: CompanionResponseInputSource,
        inputReceivedAt: Date
    ) {
        currentResponseTask?.cancel()
        stopNativeSpeechPlayback()

        let requestedModel = selectedModel.isEmpty ? "app-server-default" : selectedModel
        let requestedReasoningEffort = selectedReasoningEffortForCodexRequest ?? "default"
        let requestedServiceTier = selectedServiceTierForCodexRequest ?? "standard"
        printResponseTiming(
            source: source,
            "submitted chars=\(transcript.count) model=\(requestedModel) effort=\(requestedReasoningEffort) serviceTier=\(requestedServiceTier)",
            since: inputReceivedAt
        )

        currentResponseTask = Task {
            // Stay in processing (spinner) state — no streaming text displayed
            voiceState = .processing

            do {
                let didExecuteBackgroundAction = await executeBackgroundActionIfPlanned(
                    for: transcript,
                    source: source,
                    inputReceivedAt: inputReceivedAt
                )
                if !didExecuteBackgroundAction {
                    try await answerTranscriptWithScreenshot(
                        transcript: transcript,
                        source: source,
                        inputReceivedAt: inputReceivedAt
                    )
                }
            } catch is CancellationError {
                // User spoke again — response was interrupted
                printResponseTiming(source: source, "cancelled", since: inputReceivedAt)
            } catch {
                print("Warning: Companion response error after \(Self.formattedResponseLogDuration(Date().timeIntervalSince(inputReceivedAt))): \(error)")
                speakNativeText("I hit a snag while answering. Try that again.")
            }

            if !Task.isCancelled {
                printResponseTiming(source: source, "response task finished", since: inputReceivedAt)
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    private func executeBackgroundActionIfPlanned(
        for transcript: String,
        source: CompanionResponseInputSource,
        inputReceivedAt: Date
    ) async -> Bool {
        let backgroundContextCaptureStartedAt = Date()
        let computerUseSnapshot = CompanionBackgroundComputerUseController.snapshotForCurrentVisibleWindow()
        printResponseTiming(
            source: source,
            "background context ready hasWindow=\(computerUseSnapshot != nil) capture=\(Self.formattedResponseLogDuration(Date().timeIntervalSince(backgroundContextCaptureStartedAt)))",
            since: inputReceivedAt
        )
        ClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "incoming",
            event: "background_action.context_ready",
            fields: [
                "source": source.logName,
                "hasWindow": "\(computerUseSnapshot != nil)",
                "appName": computerUseSnapshot?.appName ?? "none",
                "windowTitle": computerUseSnapshot?.windowTitle ?? "none",
                "targetCount": "\(computerUseSnapshot?.targets.count ?? 0)"
            ]
        )

        do {
            let plannerStartedAt = Date()
            printResponseTiming(source: source, "background planner started", since: inputReceivedAt)

            let (responseText, _) = try await codexAppServerClient.analyzeTextStreaming(
                developerInstructions: Self.backgroundActionPlannerSystemPrompt,
                userPrompt: Self.backgroundActionPlannerUserPrompt(
                    transcript: transcript,
                    computerUseSnapshot: computerUseSnapshot
                ),
                model: selectedModel,
                reasoningEffort: selectedReasoningEffortForCodexRequest,
                serviceTier: selectedServiceTierForCodexRequest,
                outputSchema: Self.backgroundActionOutputSchema,
                debugLogLabel: "\(source.logName) background planner",
                onTextChunk: { _ in }
            )
            printResponseTiming(
                source: source,
                "background planner finished turn=\(Self.formattedResponseLogDuration(Date().timeIntervalSince(plannerStartedAt))) responseChars=\(responseText.count)",
                since: inputReceivedAt
            )

            let plan = try Self.decodeBackgroundActionPlan(from: responseText)
            guard plan.hasExecutableActions else {
                printResponseTiming(source: source, "background planner found no action", since: inputReceivedAt)
                ClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "event",
                    event: "background_action.no_action",
                    fields: [
                        "source": source.logName,
                        "responseCharacterCount": "\(responseText.count)"
                    ]
                )
                return false
            }

            ClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "outgoing",
                event: "background_action.plan_ready",
                fields: [
                    "source": source.logName,
                    "actionCount": "\(plan.actions.count)",
                    "spokenTextCharacterCount": "\(plan.spokenText.count)"
                ]
            )
            printResponseTiming(source: source, "executing background actions count=\(plan.actions.count)", since: inputReceivedAt)
            guard !Task.isCancelled else { return true }
            do {
                let result = try await CompanionBackgroundActionExecutor.execute(
                    plan: plan,
                    computerUseSnapshot: computerUseSnapshot
                )
                ClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "event",
                    event: "background_action.executed",
                    fields: [
                        "source": source.logName,
                        "actionCount": "\(plan.actions.count)",
                        "spokenTextCharacterCount": "\(result.spokenText.count)"
                    ]
                )
                printResponseTiming(source: source, "background actions finished", since: inputReceivedAt)
                if !result.spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    printResponseTiming(source: source, "speech starting from background action", since: inputReceivedAt)
                    speakNativeText(result.spokenText)
                }
            } catch {
                print("Warning: Background action execution failed: \(error)")
                ClickyMessageLogStore.shared.append(
                    lane: "computer-use",
                    direction: "error",
                    event: "background_action.execution_failed",
                    fields: [
                        "source": source.logName,
                        "error": error.localizedDescription
                    ]
                )
                speakNativeText(error.localizedDescription)
            }
            return true
        } catch is CancellationError {
            printResponseTiming(source: source, "background planner cancelled", since: inputReceivedAt)
            return true
        } catch {
            print("Warning: Background action planner skipped after \(Self.formattedResponseLogDuration(Date().timeIntervalSince(inputReceivedAt))): \(error)")
            ClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "error",
                event: "background_action.planner_skipped",
                fields: [
                    "source": source.logName,
                    "error": error.localizedDescription
                ]
            )
            return false
        }
    }

    private static func backgroundActionPlannerUserPrompt(
        transcript: String,
        computerUseSnapshot: CompanionBackgroundComputerUseSnapshot?
    ) -> String {
        let computerUseContext = computerUseSnapshot?.plannerContext ?? "current controlled window:\nnone"
        return """
        user message:
        \(transcript)

        \(computerUseContext)
        """
    }

    private static func companionVoiceUserPrompt(transcript: String, focusedWindowContext: String) -> String {
        """
        current focused app context:
        \(focusedWindowContext)

        user message:
        \(transcript)
        """
    }

    private func answerTranscriptWithScreenshot(
        transcript: String,
        source: CompanionResponseInputSource,
        inputReceivedAt: Date
    ) async throws {
        // Capture all connected screens so the AI has full context
        let screenshotCaptureStartedAt = Date()
        printResponseTiming(source: source, "screenshot capture started", since: inputReceivedAt)
        let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
        let screenshotCaptureDuration = Date().timeIntervalSince(screenshotCaptureStartedAt)
        let totalScreenshotBytes = screenCaptures.reduce(0) { partialByteCount, screenCapture in
            partialByteCount + screenCapture.imageData.count
        }
        printResponseTiming(
            source: source,
            "screenshot capture finished screens=\(screenCaptures.count) bytes=\(totalScreenshotBytes) capture=\(Self.formattedResponseLogDuration(screenshotCaptureDuration))",
            since: inputReceivedAt
        )

        guard !Task.isCancelled else { return }

        // Build image labels with the actual screenshot pixel dimensions
        // so Codex's coordinate space matches the image it sees. We
        // scale from screenshot pixels to display points ourselves.
        let labeledImages = screenCaptures.map { capture in
            let dimensionInfo = " (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
            return (data: capture.imageData, label: capture.label + dimensionInfo)
        }
        let focusedWindowContext = computerUseWindowContextController.focusedWindowPromptContext()
        let userPromptWithFocusedWindowContext = Self.companionVoiceUserPrompt(
            transcript: transcript,
            focusedWindowContext: focusedWindowContext
        )

        let answerTurnStartedAt = Date()
        ClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "outgoing",
            event: "voice_answer.turn_started",
            fields: [
                "source": source.logName,
                "imageCount": "\(labeledImages.count)",
                "model": selectedModel.isEmpty ? "default" : selectedModel,
                "focusedWindowContext": focusedWindowContext
            ]
        )
        printResponseTiming(source: source, "answer turn started images=\(labeledImages.count)", since: inputReceivedAt)
        let (fullResponseText, answerTurnDuration) = try await codexAppServerClient.analyzeImageStreaming(
            images: labeledImages,
            developerInstructions: Self.companionVoiceResponseSystemPrompt,
            userPrompt: userPromptWithFocusedWindowContext,
            model: selectedModel,
            reasoningEffort: selectedReasoningEffortForCodexRequest,
            serviceTier: selectedServiceTierForCodexRequest,
            debugLogLabel: "\(source.logName) answer",
            onTextChunk: { _ in
                // No streaming text display — spinner stays until speech plays
            }
        )
        ClickyMessageLogStore.shared.append(
            lane: "agent",
            direction: "incoming",
            event: "voice_answer.turn_finished",
            fields: [
                "source": source.logName,
                "clientTurnSeconds": Self.formattedResponseLogDuration(answerTurnDuration),
                "wallSeconds": Self.formattedResponseLogDuration(Date().timeIntervalSince(answerTurnStartedAt)),
                "responseCharacterCount": "\(fullResponseText.count)"
            ]
        )
        printResponseTiming(
            source: source,
            "answer turn finished clientTurn=\(Self.formattedResponseLogDuration(answerTurnDuration)) wall=\(Self.formattedResponseLogDuration(Date().timeIntervalSince(answerTurnStartedAt))) responseChars=\(fullResponseText.count)",
            since: inputReceivedAt
        )

        guard !Task.isCancelled else { return }

        // Parse the [POINT:...] tag from Codex's response
        let parseResult = Self.parsePointingCoordinates(from: fullResponseText)
        let spokenText = parseResult.spokenText

        // Handle element pointing if Codex returned coordinates.
        // Switch to idle BEFORE setting the location so the triangle
        // becomes visible and can fly to the target. Without this, the
        // spinner hides the triangle and the flight animation is invisible.
        let hasPointCoordinate = parseResult.coordinate != nil
        if hasPointCoordinate {
            voiceState = .idle
        }

        // Pick the screen capture matching Codex's screen number,
        // falling back to the cursor screen if not specified.
        let targetScreenCapture: CompanionScreenCapture? = {
            if let screenNumber = parseResult.screenNumber,
               screenNumber >= 1 && screenNumber <= screenCaptures.count {
                return screenCaptures[screenNumber - 1]
            }
            return screenCaptures.first(where: { $0.isCursorScreen })
        }()

        if let pointCoordinate = parseResult.coordinate,
           let targetScreenCapture {
            // Codex's coordinates are in the screenshot's pixel space
            // (top-left origin, e.g. 1280x831). Scale to the display's
            // point space (e.g. 1512x982), then convert to AppKit global coords.
            let screenshotWidth = CGFloat(targetScreenCapture.screenshotWidthInPixels)
            let screenshotHeight = CGFloat(targetScreenCapture.screenshotHeightInPixels)
            let displayWidth = CGFloat(targetScreenCapture.displayWidthInPoints)
            let displayHeight = CGFloat(targetScreenCapture.displayHeightInPoints)
            let displayFrame = targetScreenCapture.displayFrame

            // Clamp to screenshot coordinate space
            let clampedX = max(0, min(pointCoordinate.x, screenshotWidth))
            let clampedY = max(0, min(pointCoordinate.y, screenshotHeight))

            // Scale from screenshot pixels to display points
            let displayLocalX = clampedX * (displayWidth / screenshotWidth)
            let displayLocalY = clampedY * (displayHeight / screenshotHeight)

            // Convert from top-left origin (screenshot) to bottom-left origin (AppKit)
            let appKitY = displayHeight - displayLocalY

            // Convert display-local coords to global screen coords
            let globalLocation = CGPoint(
                x: displayLocalX + displayFrame.origin.x,
                y: appKitY + displayFrame.origin.y
            )

            detectedElementScreenLocation = globalLocation
            detectedElementDisplayFrame = displayFrame
            print("Element pointing: (\(Int(pointCoordinate.x)), \(Int(pointCoordinate.y))) → \"\(parseResult.elementLabel ?? "element")\"")
        } else {
            print("Element pointing: \(parseResult.elementLabel ?? "no element")")
        }

        if !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            printResponseTiming(source: source, "speech starting chars=\(spokenText.count)", since: inputReceivedAt)
            speakNativeText(spokenText)
        }
    }

    private static func decodeBackgroundActionPlan(from responseText: String) throws -> CompanionBackgroundActionPlan {
        let trimmedResponseText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String

        if let firstBraceIndex = trimmedResponseText.firstIndex(of: "{"),
           let lastBraceIndex = trimmedResponseText.lastIndex(of: "}"),
           firstBraceIndex <= lastBraceIndex {
            jsonText = String(trimmedResponseText[firstBraceIndex...lastBraceIndex])
        } else {
            jsonText = trimmedResponseText
        }

        let data = Data(jsonText.utf8)
        return try JSONDecoder().decode(CompanionBackgroundActionPlan.self, from: data)
    }

    /// If the cursor is in transient mode (user toggled "Show Clicky" off),
    /// waits for speech playback and any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isClickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for speech playback to finish
            while nativeSpeechSynthesizer?.isSpeaking ?? false {
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

    private func speakNativeText(_ text: String) {
        stopNativeSpeechPlayback()
        let synthesizer = NSSpeechSynthesizer()
        nativeSpeechSynthesizer = synthesizer
        synthesizer.startSpeaking(text)
        voiceState = .responding
    }

    private func stopNativeSpeechPlayback() {
        nativeSpeechSynthesizer?.stopSpeaking()
        nativeSpeechSynthesizer = nil
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from Codex's response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if Codex said "none" or no tag was found.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of Codex's response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
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

    // MARK: - Onboarding Screen-Aware Prompt

    private static let onboardingScreenAwarePromptSystemPrompt = """
    you're clicky, a small blue cursor buddy living on the user's screen. write ONE friendly onboarding message based on what you can see on their screen.

    the message should sound like: "looks like you're on this - ask me to do x, and i'll help with y."

    rules:
    - write in lowercase.
    - keep it under 24 words.
    - do not mention screenshots, images, video, onboarding, or codex.
    - do not quote private text or long visible content.
    - if the screen is unclear or sensitive, keep it generic.
    - end by telling the user to press \(BuddyPushToTalkShortcut.pushToTalkDisplayText) to talk.
    """

    func startOnboardingScreenAwarePrompt() {
        resetOnboardingPrompt()

        Task {
            do {
                let screenCaptures = try await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()
                guard let cursorScreenCapture = screenCaptures.first(where: { $0.isCursorScreen }) else {
                    startOnboardingPromptStream(message: Self.fallbackOnboardingPromptMessage)
                    return
                }

                let dimensionInfo = " (image dimensions: \(cursorScreenCapture.screenshotWidthInPixels)x\(cursorScreenCapture.screenshotHeightInPixels) pixels)"
                let labeledImages = [(data: cursorScreenCapture.imageData, label: cursorScreenCapture.label + dimensionInfo)]

                let (fullResponseText, _) = try await codexAppServerClient.analyzeImageStreaming(
                    images: labeledImages,
                    developerInstructions: Self.onboardingScreenAwarePromptSystemPrompt,
                    userPrompt: "write a short, screen-aware welcome suggestion for me",
                    model: selectedModel,
                    reasoningEffort: selectedReasoningEffortForCodexRequest,
                    serviceTier: selectedServiceTierForCodexRequest,
                    onTextChunk: { _ in }
                )

                let trimmedResponseText = fullResponseText.trimmingCharacters(in: .whitespacesAndNewlines)
                let promptMessage = trimmedResponseText.isEmpty
                    ? Self.fallbackOnboardingPromptMessage
                    : trimmedResponseText
                startOnboardingPromptStream(message: promptMessage)
            } catch {
                print("Warning: Onboarding prompt error: \(error)")
                startOnboardingPromptStream(message: Self.fallbackOnboardingPromptMessage)
            }
        }
    }

    private static let fallbackOnboardingPromptMessage = "ask me what's on your screen, and i'll help you figure out what to do next. press \(BuddyPushToTalkShortcut.pushToTalkDisplayText) to talk"

    private func resetOnboardingPrompt() {
        onboardingPromptStreamTimer?.invalidate()
        onboardingPromptStreamTimer = nil
        showOnboardingPrompt = false
        onboardingPromptText = ""
        onboardingPromptOpacity = 0.0
    }

    private func startOnboardingPromptStream(message: String) {
        onboardingPromptStreamTimer?.invalidate()
        onboardingPromptText = ""
        showOnboardingPrompt = true
        onboardingPromptOpacity = 0.0

        withAnimation(.easeIn(duration: 0.4)) {
            onboardingPromptOpacity = 1.0
        }

        var currentIndex = 0
        onboardingPromptStreamTimer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { timer in
            guard currentIndex < message.count else {
                timer.invalidate()
                self.onboardingPromptStreamTimer = nil
                self.fadeOutOnboardingMusic()
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
