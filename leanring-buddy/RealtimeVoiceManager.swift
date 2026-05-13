//
//  RealtimeVoiceManager.swift
//  leanring-buddy
//
//  Native Codex realtime voice session manager for push-to-talk audio.
//

import AVFoundation
import Combine
import Foundation
import SwiftUI

enum CodexRealtimeAvailabilityState: Equatable {
    case checking
    case available
    case unavailable(message: String)
}

@MainActor
final class RealtimeVoiceManager: ObservableObject {
    private static let inputSampleRate = 24_000
    private static let microphoneBufferFrameCount: AVAudioFrameCount = 2_048
    private static let maxPendingInputAudioBufferCount = 240

    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var availabilityState: CodexRealtimeAvailabilityState = .checking
    @Published private(set) var availableVoiceOptions: [CodexRealtimeVoiceOption] = []
    @Published private(set) var lastErrorMessage: String?
    @Published var selectedVoiceID: String = UserDefaults.standard.string(forKey: "selectedCodexRealtimeVoice") ?? ""

    private let codexAppServerClient: CodexAppServerClient
    private let microphoneEngine = AVAudioEngine()
    private var outputEngine: AVAudioEngine?
    private var outputPlayerNode: AVAudioPlayerNode?
    private var outputFormatDescription: String?
    private var activeThreadID: String?
    private var inputAudioThreadID: String?
    private var pendingInputAudioBuffers: [Data] = []
    private var isMicrophoneCaptureRunning = false
    private var shouldStopWhenRealtimeSessionStarts = false
    private var realtimeSessionClosed = false
    private var pendingOutputBufferCount = 0
    private var assistantTranscriptBuffer = ""
    private var latestScreenCaptures: [CompanionScreenCapture] = []
    private var defaultVoiceID: String?

    private var captureScreensHandler: (@MainActor () async throws -> [CompanionScreenCapture])?
    private var pointAtHandler: (@MainActor (CGPoint, CGRect, String?) -> Void)?
    private var assistantTranscriptHandler: (@MainActor (String) -> Void)?
    private var userTranscriptHandler: (@MainActor (String) -> Void)?

    init(codexAppServerClient: CodexAppServerClient = .shared) {
        self.codexAppServerClient = codexAppServerClient

        Task {
            await codexAppServerClient.setRealtimeEventHandler { [weak self] event in
                await self?.handleRealtimeEvent(event)
            }
            await codexAppServerClient.setDynamicToolHandler { [weak self] toolCall in
                guard let self else {
                    return .failure(message: "Clicky realtime tools are not ready.")
                }
                return await self.handleDynamicToolCall(toolCall)
            }
        }
    }

    var isRealtimeAvailable: Bool {
        if case .available = availabilityState {
            return true
        }
        return false
    }

    var isVoiceInputActive: Bool {
        isMicrophoneCaptureRunning
    }

    var statusText: String {
        switch availabilityState {
        case .checking:
            return "Checking"
        case .available:
            return "Ready"
        case .unavailable:
            return "Unavailable"
        }
    }

    var detailText: String {
        switch availabilityState {
        case .checking:
            return "Checking Codex realtime voice support."
        case .available:
            return "Codex realtime audio is available."
        case .unavailable(let message):
            return message
        }
    }

    var selectedVoiceDisplayName: String {
        if let selectedVoice = availableVoiceOptions.first(where: { $0.id == selectedVoiceID }) {
            return selectedVoice.displayName
        }

        if let defaultVoiceID,
           let defaultVoice = availableVoiceOptions.first(where: { $0.id == defaultVoiceID }) {
            return defaultVoice.displayName
        }

        return selectedVoiceID.isEmpty ? "Default realtime voice" : selectedVoiceID
    }

    func configure(
        captureScreens: @escaping @MainActor () async throws -> [CompanionScreenCapture],
        pointAt: @escaping @MainActor (CGPoint, CGRect, String?) -> Void,
        onAssistantTranscript: @escaping @MainActor (String) -> Void,
        onUserTranscript: @escaping @MainActor (String) -> Void
    ) {
        captureScreensHandler = captureScreens
        pointAtHandler = pointAt
        assistantTranscriptHandler = onAssistantTranscript
        userTranscriptHandler = onUserTranscript
    }

    func setSelectedVoiceID(_ voiceID: String) {
        selectedVoiceID = voiceID
        UserDefaults.standard.set(voiceID, forKey: "selectedCodexRealtimeVoice")
    }

    func refreshAvailableVoices() {
        availabilityState = .checking
        Task {
            do {
                try await loadVoiceConfiguration()
            } catch {
                availabilityState = .unavailable(message: error.localizedDescription)
                availableVoiceOptions = []
                defaultVoiceID = nil
            }
        }
    }

    func startVoiceInput(
        model: String,
        serviceTier: String?,
        systemPrompt: String
    ) async {
        cancelCurrentSession(stopRemote: true)

        guard await requestMicrophoneAccessIfNeeded() else {
            lastErrorMessage = "Microphone permission is required for realtime voice."
            voiceState = .idle
            return
        }
        guard !Task.isCancelled else {
            cancelCurrentSession(stopRemote: false)
            return
        }

        pendingInputAudioBuffers = []
        inputAudioThreadID = nil
        shouldStopWhenRealtimeSessionStarts = false
        currentAudioPowerLevel = 0
        assistantTranscriptBuffer = ""
        assistantTranscriptHandler?("")
        lastErrorMessage = nil
        realtimeSessionClosed = false
        pendingOutputBufferCount = 0

        do {
            try startMicrophoneCapture()
            print("Realtime voice: microphone capture started")
            voiceState = .listening

            let voiceID = try await selectedVoiceIDForSession()
            guard !Task.isCancelled else {
                cancelCurrentSession(stopRemote: false)
                return
            }

            let threadID = try await codexAppServerClient.ensureRealtimeThread(
                developerInstructions: systemPrompt,
                model: model,
                serviceTier: serviceTier,
                dynamicTools: Self.dynamicToolSpecs
            )
            guard !Task.isCancelled else {
                cancelCurrentSession(stopRemote: true)
                return
            }
            activeThreadID = threadID

            try await codexAppServerClient.startRealtimeSession(
                threadID: threadID,
                outputModality: "audio",
                prompt: systemPrompt,
                voiceID: voiceID
            )
            guard !Task.isCancelled else {
                cancelCurrentSession(stopRemote: true)
                return
            }

            activateInputAudioStreaming(threadID: threadID)
            print("Realtime voice: input audio streaming started")

            if shouldStopWhenRealtimeSessionStarts {
                stopMicrophoneCapture()
                currentAudioPowerLevel = 0
                voiceState = .processing
                try await codexAppServerClient.stopRealtimeSession(threadID: threadID)
                return
            }

            voiceState = .listening
        } catch {
            await handleRealtimeFailure(error.localizedDescription)
        }
    }

    func submitTextPrompt(
        _ prompt: String,
        model: String,
        serviceTier: String?,
        systemPrompt: String
    ) async {
        cancelCurrentSession(stopRemote: true)

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else { return }

        voiceState = .processing
        currentAudioPowerLevel = 0
        assistantTranscriptBuffer = ""
        assistantTranscriptHandler?("")
        lastErrorMessage = nil
        realtimeSessionClosed = false
        pendingOutputBufferCount = 0

        do {
            let voiceID = try await selectedVoiceIDForSession()
            let threadID = try await codexAppServerClient.ensureRealtimeThread(
                developerInstructions: systemPrompt,
                model: model,
                serviceTier: serviceTier,
                dynamicTools: Self.dynamicToolSpecs
            )
            activeThreadID = threadID

            try await codexAppServerClient.startRealtimeSession(
                threadID: threadID,
                outputModality: "audio",
                prompt: systemPrompt,
                voiceID: voiceID
            )
            try await codexAppServerClient.appendRealtimeText(threadID: threadID, text: trimmedPrompt)
            try await codexAppServerClient.stopRealtimeSession(threadID: threadID)
        } catch {
            await handleRealtimeFailure(error.localizedDescription)
        }
    }

    func stopVoiceInput() {
        guard isMicrophoneCaptureRunning else { return }

        stopMicrophoneCapture()
        currentAudioPowerLevel = 0
        voiceState = .processing

        guard let activeThreadID else {
            shouldStopWhenRealtimeSessionStarts = true
            return
        }

        guard inputAudioThreadID != nil else {
            shouldStopWhenRealtimeSessionStarts = true
            return
        }

        Task {
            do {
                try await codexAppServerClient.stopRealtimeSession(threadID: activeThreadID)
            } catch {
                await handleRealtimeFailure(error.localizedDescription)
            }
        }
    }

    private func handleRealtimeInputAudioFailure(_ error: Error, threadID: String) async {
        guard threadID == activeThreadID else { return }
        await handleRealtimeFailure(error.localizedDescription)
    }

    func cancelCurrentSession(stopRemote: Bool) {
        let threadID = activeThreadID
        activeThreadID = nil
        inputAudioThreadID = nil
        pendingInputAudioBuffers = []
        shouldStopWhenRealtimeSessionStarts = false
        realtimeSessionClosed = false
        pendingOutputBufferCount = 0
        assistantTranscriptBuffer = ""
        currentAudioPowerLevel = 0
        stopMicrophoneCapture()
        stopOutputPlayback()
        voiceState = .idle

        if stopRemote, let threadID {
            Task {
                try? await codexAppServerClient.stopRealtimeSession(threadID: threadID)
            }
        }
    }

    private func loadVoiceConfiguration() async throws {
        let configuration = try await codexAppServerClient.listRealtimeVoices()
        availableVoiceOptions = configuration.options
        defaultVoiceID = configuration.defaultVoiceID
        availabilityState = configuration.options.isEmpty
            ? .unavailable(message: "Codex realtime did not return any voices.")
            : .available

        if selectedVoiceID.isEmpty || !configuration.options.contains(where: { $0.id == selectedVoiceID }) {
            if let defaultVoiceID = configuration.defaultVoiceID {
                setSelectedVoiceID(defaultVoiceID)
            } else if let firstVoice = configuration.options.first {
                setSelectedVoiceID(firstVoice.id)
            }
        }
    }

    private func selectedVoiceIDForSession() async throws -> String? {
        if availableVoiceOptions.isEmpty {
            do {
                try await loadVoiceConfiguration()
            } catch {
                availabilityState = .unavailable(message: error.localizedDescription)
                throw error
            }
        }

        if !selectedVoiceID.isEmpty,
           availableVoiceOptions.contains(where: { $0.id == selectedVoiceID }) {
            return selectedVoiceID
        }

        return defaultVoiceID ?? availableVoiceOptions.first?.id
    }

    private func requestMicrophoneAccessIfNeeded() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func startMicrophoneCapture() throws {
        stopMicrophoneCapture()

        let inputNode = microphoneEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let converter = BuddyPCM16AudioConverter(targetSampleRate: Double(Self.inputSampleRate))

        inputNode.installTap(
            onBus: 0,
            bufferSize: Self.microphoneBufferFrameCount,
            format: inputFormat
        ) { [weak self] audioBuffer, _ in
            guard let pcm16Data = converter.convertToPCM16Data(from: audioBuffer),
                  !pcm16Data.isEmpty else {
                return
            }

            let powerLevel = Self.audioPowerLevel(from: audioBuffer)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentAudioPowerLevel = powerLevel
                self.handleMicrophonePCM16Data(pcm16Data)
            }
        }

        microphoneEngine.prepare()
        try microphoneEngine.start()
        isMicrophoneCaptureRunning = true
    }

    private func handleMicrophonePCM16Data(_ pcm16Data: Data) {
        guard isMicrophoneCaptureRunning else { return }

        if let inputAudioThreadID {
            appendRealtimeInputAudio(pcm16Data, threadID: inputAudioThreadID)
            return
        }

        pendingInputAudioBuffers.append(pcm16Data)
        if pendingInputAudioBuffers.count > Self.maxPendingInputAudioBufferCount {
            pendingInputAudioBuffers.removeFirst(
                pendingInputAudioBuffers.count - Self.maxPendingInputAudioBufferCount
            )
        }
    }

    private func activateInputAudioStreaming(threadID: String) {
        let pendingAudioBuffers = pendingInputAudioBuffers
        pendingInputAudioBuffers = []

        for audioData in pendingAudioBuffers {
            appendRealtimeInputAudio(audioData, threadID: threadID)
        }

        inputAudioThreadID = threadID
    }

    private func appendRealtimeInputAudio(_ audioData: Data, threadID: String) {
        let codexAppServerClient = codexAppServerClient
        Task {
            do {
                try await codexAppServerClient.appendRealtimeAudio(
                    threadID: threadID,
                    audioData: audioData,
                    sampleRate: Self.inputSampleRate,
                    channelCount: 1,
                    samplesPerChannel: audioData.count / 2
                )
            } catch {
                await handleRealtimeInputAudioFailure(error, threadID: threadID)
            }
        }
    }

    private func stopMicrophoneCapture() {
        guard isMicrophoneCaptureRunning || microphoneEngine.isRunning else { return }
        microphoneEngine.inputNode.removeTap(onBus: 0)
        microphoneEngine.stop()
        isMicrophoneCaptureRunning = false
    }

    private func handleRealtimeEvent(_ event: CodexRealtimeEvent) async {
        switch event {
        case .started(let threadID, _, _):
            guard threadID == activeThreadID else { return }
            realtimeSessionClosed = false

        case .outputAudioDelta(let audioChunk):
            guard audioChunk.threadID == activeThreadID else { return }

            do {
                try scheduleOutputAudio(audioChunk)
                voiceState = .responding
            } catch {
                await handleRealtimeFailure(error.localizedDescription)
            }

        case .transcriptDelta(let threadID, let role, let delta):
            guard threadID == activeThreadID else { return }
            guard role == "assistant" else { return }
            assistantTranscriptBuffer += delta
            assistantTranscriptHandler?(assistantTranscriptBuffer)

        case .transcriptDone(let threadID, let role, let text):
            guard threadID == activeThreadID else { return }

            if role == "assistant" {
                assistantTranscriptBuffer = text
                assistantTranscriptHandler?(text)
                await handleDefensivePointTagIfPresent(in: text)
            } else if role == "user" {
                userTranscriptHandler?(text)
            }

        case .error(let threadID, let message):
            guard threadID == activeThreadID else { return }
            await handleRealtimeFailure(message)

        case .closed(let threadID, _):
            guard threadID == activeThreadID else { return }
            realtimeSessionClosed = true
            stopMicrophoneCapture()
            finalizeIfOutputFinished()
        }
    }

    private func scheduleOutputAudio(_ audioChunk: CodexRealtimeAudioChunk) throws {
        let channelCount = max(1, audioChunk.channelCount)
        let sampleCount = audioChunk.data.count / MemoryLayout<Int16>.size
        let frameCount = sampleCount / channelCount
        guard frameCount > 0 else { return }

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(audioChunk.sampleRate),
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        ) else {
            throw CodexAppServerError.invalidResponse("Could not create realtime output audio format.")
        }

        let formatDescription = "\(audioChunk.sampleRate)-\(channelCount)"
        if outputFormatDescription != formatDescription {
            stopOutputPlayback()
            try startOutputPlayback(format: format, formatDescription: formatDescription)
        } else if outputEngine?.isRunning != true {
            try outputEngine?.start()
            outputPlayerNode?.play()
        }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            throw CodexAppServerError.invalidResponse("Could not allocate realtime output buffer.")
        }

        outputBuffer.frameLength = AVAudioFrameCount(frameCount)
        guard let channels = outputBuffer.floatChannelData else {
            throw CodexAppServerError.invalidResponse("Could not access realtime output channel data.")
        }

        for frameIndex in 0..<frameCount {
            for channelIndex in 0..<channelCount {
                let sampleIndex = frameIndex * channelCount + channelIndex
                channels[channelIndex][frameIndex] = Self.floatSample(fromPCM16Data: audioChunk.data, sampleIndex: sampleIndex)
            }
        }

        pendingOutputBufferCount += 1
        outputPlayerNode?.scheduleBuffer(outputBuffer) { [weak self] in
            Task { @MainActor [weak self] in
                self?.pendingOutputBufferCount = max(0, (self?.pendingOutputBufferCount ?? 1) - 1)
                self?.finalizeIfOutputFinished()
            }
        }
        outputPlayerNode?.play()
    }

    private func startOutputPlayback(format: AVAudioFormat, formatDescription: String) throws {
        let engine = AVAudioEngine()
        let playerNode = AVAudioPlayerNode()
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: format)
        try engine.start()
        playerNode.play()

        outputEngine = engine
        outputPlayerNode = playerNode
        outputFormatDescription = formatDescription
    }

    private func stopOutputPlayback() {
        outputPlayerNode?.stop()
        outputEngine?.stop()
        outputPlayerNode = nil
        outputEngine = nil
        outputFormatDescription = nil
    }

    private func finalizeIfOutputFinished() {
        guard realtimeSessionClosed else { return }
        guard pendingOutputBufferCount == 0 else { return }
        guard voiceState != .listening else { return }

        activeThreadID = nil
        inputAudioThreadID = nil
        pendingInputAudioBuffers = []
        shouldStopWhenRealtimeSessionStarts = false
        stopOutputPlayback()
        currentAudioPowerLevel = 0
        voiceState = .idle
    }

    private func handleRealtimeFailure(_ message: String) async {
        print("Realtime voice failed: \(message)")
        lastErrorMessage = message
        stopMicrophoneCapture()
        stopOutputPlayback()
        activeThreadID = nil
        inputAudioThreadID = nil
        pendingInputAudioBuffers = []
        shouldStopWhenRealtimeSessionStarts = false
        currentAudioPowerLevel = 0
        voiceState = .idle
    }

    private func handleDynamicToolCall(_ toolCall: CodexDynamicToolCall) async -> CodexDynamicToolResponse {
        guard toolCall.namespace == "clicky" else {
            return .failure(message: "Unsupported tool namespace.")
        }

        switch toolCall.tool {
        case "get_current_screen":
            return await currentScreenToolResponse()
        case "point_at":
            return await pointAtToolResponse(arguments: toolCall.arguments)
        default:
            return .failure(message: "Unsupported Clicky tool \(toolCall.tool).")
        }
    }

    private func currentScreenToolResponse() async -> CodexDynamicToolResponse {
        do {
            let screenCaptures = try await captureCurrentScreens()
            var contentItems: [[String: Any]] = []

            let summary = screenCaptures.enumerated().map { index, capture in
                let screenNumber = index + 1
                return "screen \(screenNumber): \(capture.label), image \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels, display \(Int(capture.displayWidthInPoints))x\(Int(capture.displayHeightInPoints)) points"
            }.joined(separator: "\n")

            contentItems.append([
                "type": "inputText",
                "text": "Current Clicky screen captures:\n\(summary)"
            ])

            for capture in screenCaptures {
                let imageURL = "data:image/jpeg;base64,\(capture.imageData.base64EncodedString())"
                contentItems.append([
                    "type": "inputText",
                    "text": "\(capture.label) (image dimensions: \(capture.screenshotWidthInPixels)x\(capture.screenshotHeightInPixels) pixels)"
                ])
                contentItems.append([
                    "type": "inputImage",
                    "imageUrl": imageURL
                ])
            }

            return .success(contentItems: contentItems)
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    private func pointAtToolResponse(arguments: [String: Any]) async -> CodexDynamicToolResponse {
        guard let x = Self.doubleValue(arguments["x"]),
              let y = Self.doubleValue(arguments["y"]) else {
            return .failure(message: "point_at requires numeric x and y arguments.")
        }

        let label = Self.stringValue(arguments["label"])
        let screenNumber = Self.intValue(arguments["screenNumber"])

        do {
            let result = try await pointAtScreenshotCoordinate(
                CGPoint(x: x, y: y),
                screenNumber: screenNumber,
                label: label
            )
            return .success(text: result)
        } catch {
            return .failure(message: error.localizedDescription)
        }
    }

    private func handleDefensivePointTagIfPresent(in text: String) async {
        let parseResult = CompanionManager.parsePointingCoordinates(from: text)
        guard let coordinate = parseResult.coordinate else { return }

        _ = try? await pointAtScreenshotCoordinate(
            coordinate,
            screenNumber: parseResult.screenNumber,
            label: parseResult.elementLabel
        )
    }

    private func pointAtScreenshotCoordinate(
        _ coordinate: CGPoint,
        screenNumber: Int?,
        label: String?
    ) async throws -> String {
        if latestScreenCaptures.isEmpty {
            _ = try await captureCurrentScreens()
        }

        let targetScreenCapture: CompanionScreenCapture? = {
            if let screenNumber,
               screenNumber >= 1,
               screenNumber <= latestScreenCaptures.count {
                return latestScreenCaptures[screenNumber - 1]
            }
            return latestScreenCaptures.first(where: { $0.isCursorScreen }) ?? latestScreenCaptures.first
        }()

        guard let targetScreenCapture else {
            throw CodexAppServerError.invalidResponse("No screen capture is available for pointing.")
        }

        let globalLocation = Self.globalScreenLocation(
            forScreenshotCoordinate: coordinate,
            in: targetScreenCapture
        )

        pointAtHandler?(globalLocation, targetScreenCapture.displayFrame, label)
        let labelText = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let labelText, !labelText.isEmpty {
            return "Pointing at \(labelText)."
        }
        return "Pointing at the requested screen location."
    }

    @discardableResult
    private func captureCurrentScreens() async throws -> [CompanionScreenCapture] {
        guard let captureScreensHandler else {
            throw CodexAppServerError.invalidResponse("Clicky screen capture is not configured.")
        }

        let screenCaptures = try await captureScreensHandler()
        latestScreenCaptures = screenCaptures
        return screenCaptures
    }

    private static func globalScreenLocation(
        forScreenshotCoordinate coordinate: CGPoint,
        in screenCapture: CompanionScreenCapture
    ) -> CGPoint {
        let screenshotWidth = CGFloat(screenCapture.screenshotWidthInPixels)
        let screenshotHeight = CGFloat(screenCapture.screenshotHeightInPixels)
        let displayWidth = CGFloat(screenCapture.displayWidthInPoints)
        let displayHeight = CGFloat(screenCapture.displayHeightInPoints)
        let displayFrame = screenCapture.displayFrame

        let clampedX = max(0, min(coordinate.x, screenshotWidth))
        let clampedY = max(0, min(coordinate.y, screenshotHeight))
        let displayLocalX = clampedX * (displayWidth / screenshotWidth)
        let displayLocalY = clampedY * (displayHeight / screenshotHeight)
        let appKitY = displayHeight - displayLocalY

        return CGPoint(
            x: displayLocalX + displayFrame.origin.x,
            y: appKitY + displayFrame.origin.y
        )
    }

    nonisolated private static func audioPowerLevel(from audioBuffer: AVAudioPCMBuffer) -> CGFloat {
        guard let channelData = audioBuffer.floatChannelData else { return 0 }

        let channelCount = Int(audioBuffer.format.channelCount)
        let frameLength = Int(audioBuffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return 0 }

        var sumOfSquares: Float = 0
        for channelIndex in 0..<channelCount {
            let samples = channelData[channelIndex]
            for frameIndex in 0..<frameLength {
                let sample = samples[frameIndex]
                sumOfSquares += sample * sample
            }
        }

        let meanSquare = sumOfSquares / Float(channelCount * frameLength)
        let rms = sqrt(max(meanSquare, 0))
        let decibels = 20 * log10(max(rms, 0.000_001))
        let normalized = (decibels + 50) / 50
        return CGFloat(max(0, min(1, normalized)))
    }

    nonisolated private static func floatSample(fromPCM16Data data: Data, sampleIndex: Int) -> Float {
        let byteIndex = sampleIndex * MemoryLayout<Int16>.size
        guard byteIndex + 1 < data.count else { return 0 }

        let lowByte = UInt16(data[data.startIndex + byteIndex])
        let highByte = UInt16(data[data.startIndex + byteIndex + 1]) << 8
        let sample = Int16(bitPattern: lowByte | highByte)
        return max(-1, min(1, Float(sample) / 32_768.0))
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            return number.doubleValue
        }
        if let string = value as? String {
            return Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static var dynamicToolSpecs: [[String: Any]] {
        [
            [
                "namespace": "clicky",
                "name": "get_current_screen",
                "description": "Capture the user's current connected screens. Returns image outputs with labels, screen numbers, screenshot pixel dimensions, and display point dimensions.",
                "inputSchema": [
                    "type": "object",
                    "properties": [:],
                    "additionalProperties": false
                ],
                "deferLoading": false
            ],
            [
                "namespace": "clicky",
                "name": "point_at",
                "description": "Move Clicky's orange cursor overlay to a screenshot pixel coordinate from the latest clicky.get_current_screen output.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "x": [
                            "type": "number",
                            "description": "X coordinate in screenshot pixels from the top-left origin."
                        ],
                        "y": [
                            "type": "number",
                            "description": "Y coordinate in screenshot pixels from the top-left origin."
                        ],
                        "label": [
                            "type": "string",
                            "description": "Short label for the element being pointed at."
                        ],
                        "screenNumber": [
                            "type": "integer",
                            "minimum": 1,
                            "description": "One-based screen number from clicky.get_current_screen. Omit to use the cursor's screen."
                        ]
                    ],
                    "required": ["x", "y"],
                    "additionalProperties": false
                ],
                "deferLoading": false
            ]
        ]
    }
}
