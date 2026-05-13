//
//  CodexAppServerClient.swift
//  Codex app-server bridge used for streaming multimodal Clicky responses.
//

import AppKit
import Foundation

struct CodexModelOption: Identifiable, Equatable {
    let id: String
    let displayName: String
    let isDefault: Bool
    let supportedReasoningEfforts: [CodexReasoningEffortOption]
    let defaultReasoningEffort: String?
    let additionalSpeedTiers: [String]

    var supportsFastMode: Bool {
        additionalSpeedTiers.contains("fast")
    }
}

struct CodexReasoningEffortOption: Identifiable, Equatable {
    let id: String
    let displayName: String
    let description: String
}

struct CodexAccountSnapshot: Equatable {
    let requiresOpenAIAuthentication: Bool
    let authMode: String?
    let planType: String?

    var isSignedIn: Bool {
        authMode == "chatgpt"
    }
}

struct CodexAppServerSnapshot: Equatable {
    let account: CodexAccountSnapshot
    let models: [CodexModelOption]
    let defaultModelID: String?
}

struct CodexRealtimeVoiceOption: Identifiable, Equatable {
    let id: String
    let displayName: String
    let generation: String
    let isDefault: Bool
}

struct CodexRealtimeVoiceConfiguration: Equatable {
    let options: [CodexRealtimeVoiceOption]
    let defaultVoiceID: String?
}

struct CodexRealtimeAudioChunk {
    let threadID: String
    let data: Data
    let sampleRate: Int
    let channelCount: Int
    let samplesPerChannel: Int?
    let itemID: String?
}

enum CodexRealtimeEvent {
    case started(threadID: String, sessionID: String?, version: String)
    case outputAudioDelta(CodexRealtimeAudioChunk)
    case transcriptDelta(threadID: String, role: String, delta: String)
    case transcriptDone(threadID: String, role: String, text: String)
    case error(threadID: String, message: String)
    case closed(threadID: String, reason: String?)
}

struct CodexDynamicToolCall {
    let threadID: String
    let turnID: String
    let callID: String
    let namespace: String?
    let tool: String
    let arguments: [String: Any]
}

struct CodexDynamicToolResponse {
    let contentItems: [[String: Any]]
    let success: Bool

    static func success(text: String) -> CodexDynamicToolResponse {
        success(contentItems: [
            [
                "type": "inputText",
                "text": text
            ]
        ])
    }

    static func success(contentItems: [[String: Any]]) -> CodexDynamicToolResponse {
        CodexDynamicToolResponse(contentItems: contentItems, success: true)
    }

    static func failure(message: String) -> CodexDynamicToolResponse {
        CodexDynamicToolResponse(
            contentItems: [
                [
                    "type": "inputText",
                    "text": message
                ]
            ],
            success: false
        )
    }
}

struct CompanionComputerUseApprovalStoreSnapshot: Equatable {
    enum State: Equatable {
        case groupContainerMissing
        case storeMissing
        case present(byteCount: Int, modifiedAt: Date?)
        case unreadable(String)
    }

    let fileURL: URL
    let state: State

    var statusText: String {
        switch state {
        case .groupContainerMissing:
            return "Container missing"
        case .storeMissing:
            return "Not created yet"
        case .present:
            return "Present"
        case .unreadable:
            return "Unreadable"
        }
    }

    var detailText: String {
        switch state {
        case .groupContainerMissing:
            return "Codex Computer Use has not initialized its app-group container."
        case .storeMissing:
            return "No persistent app approval file exists yet."
        case .present(let byteCount, let modifiedAt):
            if let modifiedAt {
                return "\(byteCount) bytes, modified \(modifiedAt.formatted(date: .abbreviated, time: .shortened))"
            }
            return "\(byteCount) bytes"
        case .unreadable(let message):
            return message
        }
    }
}

struct CompanionComputerUseMCPApprovalResult: Equatable {
    let accepted: Bool
    let appName: String?
    let bundleIdentifier: String?
    let action: String
    let reason: String
    let requestedPersistence: Bool
    let createdAt: Date

    var statusText: String {
        accepted ? "Accepted" : "Declined"
    }

    var detailText: String {
        let appText = appName ?? bundleIdentifier ?? "unknown app"
        let persistenceText = requestedPersistence ? "persistent" : "session"
        return "\(appText) - \(action), \(persistenceText): \(reason)"
    }
}

struct CompanionComputerUseMCPStatus: Equatable {
    enum DiscoveryState: Equatable {
        case checking
        case missingCodexApp
        case missingPlugin
        case missingMCPConfig
        case missingClientExecutable
        case ready
    }

    let discoveryState: DiscoveryState
    let codexAppURL: URL?
    let pluginDirectoryURL: URL?
    let clientExecutableURL: URL?
    let mcpServerFound: Bool
    let mcpToolCount: Int
    let approvalStore: CompanionComputerUseApprovalStoreSnapshot
    let currentAppName: String?
    let currentBundleIdentifier: String?
    let lastApprovalResult: CompanionComputerUseMCPApprovalResult?
    let lastRefreshErrorMessage: String?

    static func checking() -> CompanionComputerUseMCPStatus {
        let approvalStore = CodexAppServerClient.computerUseApprovalStoreSnapshot()
        return CompanionComputerUseMCPStatus(
            discoveryState: .checking,
            codexAppURL: nil,
            pluginDirectoryURL: nil,
            clientExecutableURL: nil,
            mcpServerFound: false,
            mcpToolCount: 0,
            approvalStore: approvalStore,
            currentAppName: nil,
            currentBundleIdentifier: nil,
            lastApprovalResult: nil,
            lastRefreshErrorMessage: nil
        )
    }

    var isReadyForAppApproval: Bool {
        discoveryState == .ready && mcpServerFound && lastRefreshErrorMessage == nil
    }

    var discoveryStatusText: String {
        switch discoveryState {
        case .checking:
            return "Checking"
        case .missingCodexApp:
            return "Codex app missing"
        case .missingPlugin:
            return "Plugin missing"
        case .missingMCPConfig:
            return "MCP config missing"
        case .missingClientExecutable:
            return "Client missing"
        case .ready:
            return "Plugin ready"
        }
    }

    var appApprovalStatusText: String {
        if let lastRefreshErrorMessage, !lastRefreshErrorMessage.isEmpty {
            return "Unavailable"
        }
        if isReadyForAppApproval {
            return "Ready"
        }
        return discoveryStatusText
    }

    var appApprovalDetailText: String {
        if let lastRefreshErrorMessage, !lastRefreshErrorMessage.isEmpty {
            return lastRefreshErrorMessage
        }
        if isReadyForAppApproval {
            return "Auto-allows the current focused app through MCP elicitation."
        }
        return "Codex Computer Use MCP is not ready yet."
    }
}

enum CodexAppServerError: LocalizedError {
    case codexExecutableNotFound
    case invalidCodexExecutablePath(String)
    case invalidResponse(String)
    case serverError(String)
    case accountAuthenticationRequired
    case processExited(Int32)
    case appServerUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .codexExecutableNotFound:
            return "Codex CLI was not found. Install it with pnpm or set CodexCLIPath in Info.plist."
        case .invalidCodexExecutablePath(let path):
            return "CodexCLIPath points to a non-executable file: \(path)"
        case .invalidResponse(let message):
            return "Codex app-server returned an unexpected response: \(message)"
        case .serverError(let message):
            return message
        case .accountAuthenticationRequired:
            return "Sign in to Codex with ChatGPT before using Clicky."
        case .processExited(let exitCode):
            return "Codex app-server exited unexpectedly with code \(exitCode)."
        case .appServerUnavailable(let message):
            return message
        }
    }
}

actor CodexAppServerClient {
    static let shared = CodexAppServerClient()

    typealias RealtimeEventHandler = @MainActor (CodexRealtimeEvent) async -> Void
    typealias DynamicToolHandler = @MainActor (CodexDynamicToolCall) async -> CodexDynamicToolResponse

    private struct ProcessContext {
        let process: Process
        let stdinHandle: FileHandle
        let stdoutPipe: Pipe
        let stderrPipe: Pipe
    }

    private struct ActiveTurn {
        let turnID: String
        let requestStartedAt: Date
        let turnStartedAt: Date
        let debugLogLabel: String?
        let onTextChunk: @MainActor @Sendable (String) -> Void
        let continuation: CheckedContinuation<(text: String, duration: TimeInterval, invokedComputerUseInteraction: Bool), Error>
        var accumulatedText: String
        var hasLoggedFirstTextChunk: Bool
        var invokedComputerUseInteraction: Bool
    }

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<Any, Error>
    }

    private struct ComputerUseMCPServerConfiguration {
        let codexAppURL: URL
        let pluginDirectoryURL: URL
        let clientExecutableURL: URL
        let command: String
        let args: [String]
        let cwd: String
    }

    private struct FrontmostApplicationSnapshot {
        let name: String?
        let bundleIdentifier: String?
    }

    private let session = URLSession(configuration: .default)
    private var processContext: ProcessContext?
    private var startupTask: Task<Void, Error>?
    private var pendingResponses: [Int: PendingRequest] = [:]
    private var nextRequestID = 1
    private var activeTurn: ActiveTurn?
    private var threadIDsByThreadConfiguration: [String: String] = [:]
    private var activeCodexExecutablePath: String?
    private var lastComputerUseMCPApprovalResult: CompanionComputerUseMCPApprovalResult?
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
    private var realtimeEventHandler: RealtimeEventHandler?
    private var dynamicToolHandler: DynamicToolHandler?
    private let requestTimeoutNanoseconds: UInt64 = 8_000_000_000

    private static func formattedLogDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return "\(Int((duration * 1_000).rounded()))ms"
        }

        return String(format: "%.2fs", duration)
    }

    private static func printTiming(label: String?, _ message: String) {
        guard let label else { return }
        print("Timing: Codex \(label): \(message)")
    }

    private static func requestConfigurationDescription(
        model: String,
        reasoningEffort: String?,
        serviceTier: String?
    ) -> String {
        let modelDescription = model.isEmpty ? "app-server-default" : model
        let reasoningEffortDescription = reasoningEffort ?? "default"
        let serviceTierDescription = serviceTier ?? "standard"
        return "model=\(modelDescription) effort=\(reasoningEffortDescription) serviceTier=\(serviceTierDescription)"
    }

    private static func logFirstTextChunkIfNeeded(
        activeTurn: inout ActiveTurn,
        notificationName: String
    ) {
        guard !activeTurn.hasLoggedFirstTextChunk else { return }

        activeTurn.hasLoggedFirstTextChunk = true
        let now = Date()
        printTiming(
            label: activeTurn.debugLogLabel,
            "first text via \(notificationName) total=\(formattedLogDuration(now.timeIntervalSince(activeTurn.requestStartedAt))) turn=\(formattedLogDuration(now.timeIntervalSince(activeTurn.turnStartedAt)))"
        )
    }

    func refreshSnapshot() async throws -> CodexAppServerSnapshot {
        try await ensureConnection()

        let accountResult = try await requestObject(
            method: "account/read",
            params: ["refreshToken": false]
        )
        let modelResult = try await requestObject(
            method: "model/list",
            params: [
                "includeHidden": false,
                "limit": 50
            ]
        )

        let accountSnapshot = Self.parseAccountSnapshot(from: accountResult)
        let modelOptions = Self.parseModelOptions(from: modelResult)
        let defaultModelID = modelOptions.first(where: \.isDefault)?.id ?? modelOptions.first?.id

        return CodexAppServerSnapshot(
            account: accountSnapshot,
            models: modelOptions,
            defaultModelID: defaultModelID
        )
    }

    func refreshComputerUseMCPStatus() async -> CompanionComputerUseMCPStatus {
        let discovery = Self.computerUseMCPServerConfiguration()
        let approvalStore = Self.computerUseApprovalStoreSnapshot()
        let frontmostApplication = await Self.frontmostRegularApplicationSnapshot()

        do {
            try await ensureConnection()
            let serverStatusResult = try await requestObject(
                method: "mcpServerStatus/list",
                params: ["detail": "toolsAndAuthOnly"]
            )
            let serverStatuses = serverStatusResult["data"] as? [[String: Any]] ?? []
            let computerUseServerStatus = serverStatuses.first { serverStatus in
                serverStatus["name"] as? String == "computer-use"
            }
            let tools = computerUseServerStatus?["tools"] as? [String: Any] ?? [:]

            return CompanionComputerUseMCPStatus(
                discoveryState: discovery.discoveryState,
                codexAppURL: discovery.configuration?.codexAppURL,
                pluginDirectoryURL: discovery.configuration?.pluginDirectoryURL,
                clientExecutableURL: discovery.configuration?.clientExecutableURL,
                mcpServerFound: computerUseServerStatus != nil,
                mcpToolCount: tools.count,
                approvalStore: approvalStore,
                currentAppName: frontmostApplication?.name,
                currentBundleIdentifier: frontmostApplication?.bundleIdentifier,
                lastApprovalResult: lastComputerUseMCPApprovalResult,
                lastRefreshErrorMessage: nil
            )
        } catch {
            return CompanionComputerUseMCPStatus(
                discoveryState: discovery.discoveryState,
                codexAppURL: discovery.configuration?.codexAppURL,
                pluginDirectoryURL: discovery.configuration?.pluginDirectoryURL,
                clientExecutableURL: discovery.configuration?.clientExecutableURL,
                mcpServerFound: false,
                mcpToolCount: 0,
                approvalStore: approvalStore,
                currentAppName: frontmostApplication?.name,
                currentBundleIdentifier: frontmostApplication?.bundleIdentifier,
                lastApprovalResult: lastComputerUseMCPApprovalResult,
                lastRefreshErrorMessage: error.localizedDescription
            )
        }
    }

    func startChatGPTLogin() async throws -> URL {
        try await ensureConnection()

        let response = try await requestObject(
            method: "account/login/start",
            params: ["type": "chatgpt"]
        )

        guard let type = response["type"] as? String else {
            throw CodexAppServerError.invalidResponse("Missing login type.")
        }

        switch type {
        case "chatgpt":
            guard let authURLString = response["authUrl"] as? String,
                  let authURL = URL(string: authURLString) else {
                throw CodexAppServerError.invalidResponse("Missing ChatGPT auth URL.")
            }
            return authURL
        case "chatgptDeviceCode":
            guard let verificationURLString = response["verificationUrl"] as? String,
                  let verificationURL = URL(string: verificationURLString),
                  let userCode = response["userCode"] as? String else {
                throw CodexAppServerError.invalidResponse("Missing ChatGPT device-code payload.")
            }

            print("Codex device login code: \(userCode)")
            return verificationURL
        default:
            throw CodexAppServerError.invalidResponse("Unsupported login type \(type).")
        }
    }

    func setRealtimeEventHandler(_ handler: RealtimeEventHandler?) {
        realtimeEventHandler = handler
    }

    func setDynamicToolHandler(_ handler: DynamicToolHandler?) {
        dynamicToolHandler = handler
    }

    func listRealtimeVoices() async throws -> CodexRealtimeVoiceConfiguration {
        try await ensureConnection()

        let response = try await requestObject(
            method: "thread/realtime/listVoices",
            params: [:]
        )

        return try Self.parseRealtimeVoiceConfiguration(from: response)
    }

    func ensureRealtimeThread(
        developerInstructions: String,
        model: String,
        serviceTier: String?,
        dynamicTools: [[String: Any]]
    ) async throws -> String {
        let snapshot = try await refreshSnapshot()
        if snapshot.account.requiresOpenAIAuthentication && !snapshot.account.isSignedIn {
            throw CodexAppServerError.accountAuthenticationRequired
        }

        return try await ensureThread(
            developerInstructions: developerInstructions,
            model: model,
            serviceTier: serviceTier,
            dynamicTools: dynamicTools
        )
    }

    func startRealtimeSession(
        threadID: String,
        outputModality: String,
        prompt: String?,
        voiceID: String?
    ) async throws {
        var params: [String: Any] = [
            "threadId": threadID,
            "outputModality": outputModality,
            "transport": [
                "type": "websocket"
            ]
        ]

        if let prompt {
            params["prompt"] = prompt
        }

        if let voiceID, !voiceID.isEmpty {
            params["voice"] = voiceID
        }

        _ = try await requestObject(
            method: "thread/realtime/start",
            params: params
        )
    }

    func appendRealtimeAudio(
        threadID: String,
        audioData: Data,
        sampleRate: Int,
        channelCount: Int,
        samplesPerChannel: Int?
    ) async throws {
        var audio: [String: Any] = [
            "data": audioData.base64EncodedString(),
            "sampleRate": sampleRate,
            "numChannels": channelCount
        ]

        if let samplesPerChannel {
            audio["samplesPerChannel"] = samplesPerChannel
        }

        _ = try await requestObject(
            method: "thread/realtime/appendAudio",
            params: [
                "threadId": threadID,
                "audio": audio
            ]
        )
    }

    func appendRealtimeText(threadID: String, text: String) async throws {
        _ = try await requestObject(
            method: "thread/realtime/appendText",
            params: [
                "threadId": threadID,
                "text": text
            ]
        )
    }

    func stopRealtimeSession(threadID: String) async throws {
        _ = try await requestObject(
            method: "thread/realtime/stop",
            params: [
                "threadId": threadID
            ]
        )
    }

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        developerInstructions: String,
        userPrompt: String,
        model: String,
        reasoningEffort: String?,
        serviceTier: String?,
        debugLogLabel: String? = nil,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval, invokedComputerUseInteraction: Bool) {
        let requestStartedAt = Date()
        Self.printTiming(
            label: debugLogLabel,
            "image request started images=\(images.count) \(Self.requestConfigurationDescription(model: model, reasoningEffort: reasoningEffort, serviceTier: serviceTier))"
        )

        let snapshot = try await refreshSnapshot()
        Self.printTiming(
            label: debugLogLabel,
            "snapshot ready total=\(Self.formattedLogDuration(Date().timeIntervalSince(requestStartedAt)))"
        )
        if snapshot.account.requiresOpenAIAuthentication && !snapshot.account.isSignedIn {
            throw CodexAppServerError.accountAuthenticationRequired
        }

        let temporaryImageURLs = try Self.writeTemporaryImages(images: images)
        Self.printTiming(
            label: debugLogLabel,
            "temporary images written count=\(temporaryImageURLs.count) total=\(Self.formattedLogDuration(Date().timeIntervalSince(requestStartedAt)))"
        )
        defer {
            Self.removeTemporaryFiles(at: temporaryImageURLs)
        }

        let threadRequestStartedAt = Date()
        let threadID = try await ensureThread(
            developerInstructions: developerInstructions,
            model: model,
            serviceTier: serviceTier
        )
        Self.printTiming(
            label: debugLogLabel,
            "thread ready thread=\(Self.formattedLogDuration(Date().timeIntervalSince(threadRequestStartedAt))) total=\(Self.formattedLogDuration(Date().timeIntervalSince(requestStartedAt)))"
        )

        var input: [[String: Any]] = []
        for (index, image) in images.enumerated() {
            input.append([
                "type": "localImage",
                "path": temporaryImageURLs[index].path
            ])
            input.append([
                "type": "text",
                "text": image.label
            ])
        }
        input.append([
            "type": "text",
            "text": userPrompt
        ])

        let turnStartRequestStartedAt = Date()
        let turnResult = try await requestObject(
            method: "turn/start",
            params: turnStartParams(
                [
                    "threadId": threadID,
                    "input": input,
                    "model": model
                ],
                reasoningEffort: reasoningEffort,
                serviceTier: serviceTier
            )
        )
        Self.printTiming(
            label: debugLogLabel,
            "turn/start acknowledged request=\(Self.formattedLogDuration(Date().timeIntervalSince(turnStartRequestStartedAt))) total=\(Self.formattedLogDuration(Date().timeIntervalSince(requestStartedAt)))"
        )

        guard let turn = turnResult["turn"] as? [String: Any],
              let turnID = turn["id"] as? String else {
            throw CodexAppServerError.invalidResponse("Missing turn id.")
        }

        return try await withCheckedThrowingContinuation { continuation in
            activeTurn = ActiveTurn(
                turnID: turnID,
                requestStartedAt: requestStartedAt,
                turnStartedAt: Date(),
                debugLogLabel: debugLogLabel,
                onTextChunk: onTextChunk,
                continuation: continuation,
                accumulatedText: "",
                hasLoggedFirstTextChunk: false,
                invokedComputerUseInteraction: false
            )
        }
    }

    func analyzeTextStreaming(
        developerInstructions: String,
        userPrompt: String,
        model: String,
        reasoningEffort: String?,
        serviceTier: String?,
        outputSchema: [String: Any]? = nil,
        debugLogLabel: String? = nil,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
        let requestStartedAt = Date()
        Self.printTiming(
            label: debugLogLabel,
            "text request started schema=\(outputSchema != nil) \(Self.requestConfigurationDescription(model: model, reasoningEffort: reasoningEffort, serviceTier: serviceTier))"
        )

        let snapshot = try await refreshSnapshot()
        Self.printTiming(
            label: debugLogLabel,
            "snapshot ready total=\(Self.formattedLogDuration(Date().timeIntervalSince(requestStartedAt)))"
        )
        if snapshot.account.requiresOpenAIAuthentication && !snapshot.account.isSignedIn {
            throw CodexAppServerError.accountAuthenticationRequired
        }

        let threadRequestStartedAt = Date()
        let threadID = try await ensureThread(
            developerInstructions: developerInstructions,
            model: model,
            serviceTier: serviceTier
        )
        Self.printTiming(
            label: debugLogLabel,
            "thread ready thread=\(Self.formattedLogDuration(Date().timeIntervalSince(threadRequestStartedAt))) total=\(Self.formattedLogDuration(Date().timeIntervalSince(requestStartedAt)))"
        )

        var turnParams = turnStartParams(
            [
                "threadId": threadID,
                "input": [
                    [
                        "type": "text",
                        "text": userPrompt
                    ]
                ],
                "model": model
            ],
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier
        )

        if let outputSchema {
            turnParams["outputSchema"] = outputSchema
        }

        let turnStartRequestStartedAt = Date()
        let turnResult = try await requestObject(
            method: "turn/start",
            params: turnParams
        )
        Self.printTiming(
            label: debugLogLabel,
            "turn/start acknowledged request=\(Self.formattedLogDuration(Date().timeIntervalSince(turnStartRequestStartedAt))) total=\(Self.formattedLogDuration(Date().timeIntervalSince(requestStartedAt)))"
        )

        guard let turn = turnResult["turn"] as? [String: Any],
              let turnID = turn["id"] as? String else {
            throw CodexAppServerError.invalidResponse("Missing turn id.")
        }

        let result = try await withCheckedThrowingContinuation { continuation in
            activeTurn = ActiveTurn(
                turnID: turnID,
                requestStartedAt: requestStartedAt,
                turnStartedAt: Date(),
                debugLogLabel: debugLogLabel,
                onTextChunk: onTextChunk,
                continuation: continuation,
                accumulatedText: "",
                hasLoggedFirstTextChunk: false,
                invokedComputerUseInteraction: false
            )
        }
        return (result.text, result.duration)
    }

    private func ensureConnection() async throws {
        if processContext != nil {
            return
        }

        if let startupTask {
            return try await startupTask.value
        }

        let startupTask = Task { try await launchProcessAndInitialize() }
        self.startupTask = startupTask

        do {
            try await startupTask.value
            self.startupTask = nil
        } catch {
            self.startupTask = nil
            throw error
        }
    }

    private func launchProcessAndInitialize() async throws {
        let codexExecutableURL = try Self.resolveCodexExecutableURL()
        let appServerWorkingDirectoryURL = try Self.appServerWorkingDirectoryURL()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let process = Process()
        process.executableURL = codexExecutableURL
        let computerUseMCPDiscovery = Self.computerUseMCPServerConfiguration()
        process.arguments = Self.appServerArguments(
            computerUseMCPServerConfiguration: computerUseMCPDiscovery.configuration
        )
        process.environment = Self.processEnvironment(for: codexExecutableURL)
        process.currentDirectoryURL = appServerWorkingDirectoryURL
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { process in
            Task {
                await self.handleProcessTermination(exitCode: process.terminationStatus)
            }
        }

        do {
            try process.run()
        } catch {
            throw CodexAppServerError.appServerUnavailable(error.localizedDescription)
        }

        processContext = ProcessContext(
            process: process,
            stdinHandle: stdinPipe.fileHandleForWriting,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe
        )
        activeCodexExecutablePath = codexExecutableURL.path

        startOutputReaders(stdoutPipe: stdoutPipe, stderrPipe: stderrPipe)

        do {
            _ = try await requestObject(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "clicky",
                        "title": "Clicky",
                        "version": Self.clientVersion
                    ],
                    "capabilities": [
                        "experimentalApi": true
                    ]
                ]
            )

            try await sendNotification(method: "initialized")
        } catch {
            tearDownProcess()
            throw error
        }
    }

    private func ensureThread(
        developerInstructions: String,
        model: String,
        serviceTier: String?,
        dynamicTools: [[String: Any]]? = nil
    ) async throws -> String {
        let dynamicToolsKey = Self.jsonConfigurationKey(dynamicTools ?? [])
        let threadConfigurationKey = model + "\n" + (serviceTier ?? "standard") + "\n" + dynamicToolsKey + "\n" + developerInstructions
        if let existingThreadID = threadIDsByThreadConfiguration[threadConfigurationKey] {
            return existingThreadID
        }

        var threadParams: [String: Any] = [
            "model": model,
            "approvalPolicy": [
                "granular": [
                    "sandbox_approval": false,
                    "rules": false,
                    "skill_approval": false,
                    "request_permissions": false,
                    "mcp_elicitations": true
                ]
            ],
            "serviceName": "clicky",
            "developerInstructions": developerInstructions,
            "personality": "friendly",
            "ephemeral": true,
            "experimentalRawEvents": false,
            "persistExtendedHistory": false
        ]
        threadParams["serviceTier"] = Self.serviceTierParameterValue(serviceTier)
        if let dynamicTools, !dynamicTools.isEmpty {
            threadParams["dynamicTools"] = dynamicTools
        }

        let result = try await requestObject(
            method: "thread/start",
            params: threadParams
        )

        guard let thread = result["thread"] as? [String: Any],
              let threadID = thread["id"] as? String else {
            throw CodexAppServerError.invalidResponse("Missing thread id.")
        }

        threadIDsByThreadConfiguration[threadConfigurationKey] = threadID
        return threadID
    }

    private func requestObject(method: String, params: [String: Any]) async throws -> [String: Any] {
        let rawResult = try await request(method: method, params: params)
        guard let result = rawResult as? [String: Any] else {
            throw CodexAppServerError.invalidResponse("Response for \(method) was not an object.")
        }
        return result
    }

    private func turnStartParams(
        _ baseParams: [String: Any],
        reasoningEffort: String?,
        serviceTier: String?
    ) -> [String: Any] {
        var params = baseParams
        params["personality"] = "friendly"
        params["serviceTier"] = Self.serviceTierParameterValue(serviceTier)

        if let reasoningEffort {
            params["effort"] = reasoningEffort
        }

        return params
    }

    private static func serviceTierParameterValue(_ serviceTier: String?) -> Any {
        serviceTier ?? NSNull()
    }

    private static func jsonConfigurationKey(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }

    private func request(method: String, params: [String: Any]) async throws -> Any {
        try await ensureConnection()

        let requestID = nextRequestID
        nextRequestID += 1

        return try await withCheckedThrowingContinuation { continuation in
            pendingResponses[requestID] = PendingRequest(
                method: method,
                continuation: continuation
            )

            do {
                try sendJSONLine([
                    "jsonrpc": "2.0",
                    "method": method,
                    "id": requestID,
                    "params": params
                ])

                Task {
                    try? await Task.sleep(nanoseconds: requestTimeoutNanoseconds)
                    await self.handleRequestTimeout(requestID: requestID, method: method)
                }
            } catch {
                pendingResponses.removeValue(forKey: requestID)
                continuation.resume(throwing: error)
            }
        }
    }

    private func sendNotification(method: String) async throws {
        try await ensureConnection()
        try sendJSONLine([
            "jsonrpc": "2.0",
            "method": method,
            "params": [:]
        ])
    }

    private func sendJSONLine(_ payload: [String: Any]) throws {
        guard let processContext else {
            throw CodexAppServerError.appServerUnavailable("Codex app-server is not running.")
        }

        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        var lineData = jsonData
        lineData.append(0x0A)
        processContext.stdinHandle.write(lineData)
    }

    private func startOutputReaders(stdoutPipe: Pipe, stderrPipe: Pipe) {
        let codexExecutablePath = activeCodexExecutablePath

        stdoutPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            Task {
                await self.handleStdoutData(data)
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            guard !data.isEmpty else { return }
            Task {
                await self.handleStderrData(data, codexExecutablePath: codexExecutablePath)
            }
        }
    }

    private func handleStdoutData(_ data: Data) async {
        guard let chunk = String(data: data, encoding: .utf8) else {
            return
        }

        stdoutBuffer += chunk
        while let newlineRange = stdoutBuffer.range(of: "\n") {
            let line = String(stdoutBuffer[..<newlineRange.lowerBound])
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex..<newlineRange.upperBound)
            await handleServerLine(line)
        }
    }

    private func handleStderrData(_ data: Data, codexExecutablePath: String?) {
        guard let chunk = String(data: data, encoding: .utf8) else {
            return
        }

        stderrBuffer += chunk
        while let newlineRange = stderrBuffer.range(of: "\n") {
            let line = String(stderrBuffer[..<newlineRange.lowerBound])
            stderrBuffer.removeSubrange(stderrBuffer.startIndex..<newlineRange.upperBound)
            Self.printServerDiagnostic(line, codexExecutablePath: codexExecutablePath)
        }
    }

    private static func printServerDiagnostic(_ line: String, codexExecutablePath: String?) {
        if line.contains("exec: node: not found") {
            let codexPath = codexExecutablePath ?? "the Codex executable"
            print("Warning: Codex app-server could not find Node.js while running \(codexPath). Clicky adds common Node install paths automatically; if this continues, set CodexCLIPath to a bundled Codex executable or install Node in /opt/homebrew/bin.")
            return
        }

        print("Codex app-server: \(line)")
    }

    private func handleServerLine(_ line: String) async {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty,
              let lineData = trimmedLine.data(using: .utf8) else {
            return
        }

        guard let jsonObject = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
            print("Warning: Codex stdout non-JSON line: \(trimmedLine)")
            return
        }

        if let method = jsonObject["method"] as? String,
           let requestID = jsonObject["id"],
           !(requestID is NSNull) {
            await handleServerRequest(
                requestID: requestID,
                method: method,
                params: jsonObject["params"] as? [String: Any] ?? [:]
            )
            return
        }

        if let method = jsonObject["method"] as? String,
           let params = jsonObject["params"] as? [String: Any] {
            await handleNotification(method: method, params: params)
            return
        }

        guard let requestID = Self.parseRequestID(from: jsonObject["id"]) else {
            return
        }

        guard let pendingRequest = pendingResponses.removeValue(forKey: requestID) else {
            return
        }

        if let errorObject = jsonObject["error"] as? [String: Any] {
            let message = errorObject["message"] as? String ?? "Unknown Codex app-server error."
            pendingRequest.continuation.resume(throwing: CodexAppServerError.serverError(message))
            return
        }

        pendingRequest.continuation.resume(returning: jsonObject["result"] as Any)
    }

    private func handleRequestTimeout(requestID: Int, method: String) async {
        guard let pendingRequest = pendingResponses.removeValue(forKey: requestID) else {
            return
        }

        tearDownProcess()
        pendingRequest.continuation.resume(
            throwing: CodexAppServerError.appServerUnavailable(
                "Codex app-server did not respond to \(method)."
            )
        )
    }

    private func handleServerRequest(requestID: Any, method: String, params: [String: Any]) async {
        let result: [String: Any]

        switch method {
        case "mcpServer/elicitation/request":
            result = await computerUseElicitationResponse(params: params)
        case "item/tool/call":
            result = await dynamicToolCallResponse(params: params)
        default:
            do {
                try sendJSONLine([
                    "jsonrpc": "2.0",
                    "id": requestID,
                    "error": [
                        "code": -32601,
                        "message": "Unsupported app-server request \(method)."
                    ]
                ])
            } catch {
                print("Warning: Codex app-server request response failed: \(error.localizedDescription)")
            }
            return
        }

        do {
            try sendJSONLine([
                "jsonrpc": "2.0",
                "id": requestID,
                "result": result
            ])
        } catch {
            print("Warning: Codex app-server request response failed: \(error.localizedDescription)")
        }
    }

    private func dynamicToolCallResponse(params: [String: Any]) async -> [String: Any] {
        guard let toolCall = Self.parseDynamicToolCall(from: params) else {
            let response = CodexDynamicToolResponse.failure(message: "Clicky could not parse the dynamic tool call.")
            return [
                "contentItems": response.contentItems,
                "success": response.success
            ]
        }

        guard let dynamicToolHandler else {
            let response = CodexDynamicToolResponse.failure(message: "Clicky has no dynamic tool handler registered.")
            return [
                "contentItems": response.contentItems,
                "success": response.success
            ]
        }

        let response = await dynamicToolHandler(toolCall)
        return [
            "contentItems": response.contentItems,
            "success": response.success
        ]
    }

    private func computerUseElicitationResponse(params: [String: Any]) async -> [String: Any] {
        Self.logComputerUseElicitationReceived(params: params)

        guard params["serverName"] as? String == "computer-use" else {
            recordComputerUseMCPApprovalResult(
                accepted: false,
                app: nil,
                action: "decline",
                reason: "Elicitation was not from computer-use.",
                requestedPersistence: false
            )
            return declinedElicitationResponse()
        }

        guard params["mode"] as? String == "form",
              let requestedSchema = params["requestedSchema"] as? [String: Any] else {
            recordComputerUseMCPApprovalResult(
                accepted: false,
                app: nil,
                action: "decline",
                reason: "Only form-mode Computer Use elicitations can be auto-approved.",
                requestedPersistence: false
            )
            return declinedElicitationResponse()
        }

        guard let frontmostApplication = await Self.frontmostRegularApplicationSnapshot() else {
            recordComputerUseMCPApprovalResult(
                accepted: false,
                app: nil,
                action: "decline",
                reason: "No regular frontmost app was available.",
                requestedPersistence: false
            )
            return declinedElicitationResponse()
        }

        guard Self.elicitation(params: params, mentions: frontmostApplication) else {
            recordComputerUseMCPApprovalResult(
                accepted: false,
                app: frontmostApplication,
                action: "decline",
                reason: "Requested app did not match the current focused app.",
                requestedPersistence: false
            )
            return declinedElicitationResponse()
        }

        guard let content = Self.acceptedComputerUseElicitationContent(
            from: requestedSchema,
            for: frontmostApplication
        ) else {
            recordComputerUseMCPApprovalResult(
                accepted: false,
                app: frontmostApplication,
                action: "decline",
                reason: "Requested schema was not safely fillable.",
                requestedPersistence: false
            )
            return declinedElicitationResponse()
        }

        let requestedPersistence = Self.contentRequestsPersistence(content)
        recordComputerUseMCPApprovalResult(
            accepted: true,
            app: frontmostApplication,
            action: "accept",
            reason: "Requested app matched the current focused app.",
            requestedPersistence: requestedPersistence
        )
        return [
            "action": "accept",
            "content": content,
            "_meta": NSNull()
        ]
    }

    private func declinedElicitationResponse() -> [String: Any] {
        [
            "action": "decline",
            "content": NSNull(),
            "_meta": NSNull()
        ]
    }

    private func recordComputerUseMCPApprovalResult(
        accepted: Bool,
        app: FrontmostApplicationSnapshot?,
        action: String,
        reason: String,
        requestedPersistence: Bool
    ) {
        let result = CompanionComputerUseMCPApprovalResult(
            accepted: accepted,
            appName: app?.name,
            bundleIdentifier: app?.bundleIdentifier,
            action: action,
            reason: reason,
            requestedPersistence: requestedPersistence,
            createdAt: Date()
        )
        lastComputerUseMCPApprovalResult = result

        if accepted {
            markActiveTurnComputerUseInvoked()
        }

        ClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "event",
            event: accepted ? "mcp_app_approval.accepted" : "mcp_app_approval.declined",
            fields: [
                "appName": app?.name ?? "unknown",
                "bundleIdentifier": app?.bundleIdentifier ?? "unknown",
                "action": action,
                "reason": reason,
                "requestedPersistence": "\(requestedPersistence)"
            ]
        )
    }

    private static let computerUseLogFieldMaxLength = 400

    private static func logComputerUseElicitationReceived(params: [String: Any]) {
        let serverName = trimmedNonEmptyString(params["serverName"]) ?? "unknown"
        let mode = trimmedNonEmptyString(params["mode"]) ?? "unknown"
        var fields: [String: String] = [
            "serverName": serverName,
            "mode": mode
        ]
        if let message = params["message"] as? String {
            fields["message"] = truncateForComputerUseLogField(message)
        }
        if let elicitationID = trimmedNonEmptyString(params["elicitationId"])
            ?? trimmedNonEmptyString(params["id"]) {
            fields["elicitationId"] = truncateForComputerUseLogField(elicitationID)
        }
        if let requestedSchema = params["requestedSchema"] as? [String: Any] {
            fields["requestedSchemaKeys"] = requestedSchema.keys.sorted().joined(separator: ",")
        }
        ClickyMessageLogStore.shared.append(
            lane: "computer-use",
            direction: "incoming",
            event: "mcp_elicitation.received",
            fields: fields
        )
    }

    private static func computerUseLogSummaryForCompletedItem(_ item: [String: Any]) -> String {
        let candidateKeys = ["name", "toolName", "tool", "callId", "status", "id", "mcpServer", "serverName"]
        for key in candidateKeys {
            if let string = item[key] as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return truncateForComputerUseLogField(string)
            }
            if let number = item[key] {
                let text = String(describing: number)
                if !text.isEmpty {
                    return truncateForComputerUseLogField(text)
                }
            }
        }
        let keysPreview = item.keys.sorted().prefix(12).joined(separator: ",")
        return truncateForComputerUseLogField(keysPreview.isEmpty ? "no_keys" : "keys=\(keysPreview)")
    }

    private static func truncateForComputerUseLogField(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > computerUseLogFieldMaxLength else {
            return trimmed
        }
        let endIndex = trimmed.index(trimmed.startIndex, offsetBy: computerUseLogFieldMaxLength)
        return String(trimmed[..<endIndex]) + "..."
    }

    private static func trimmedNonEmptyString(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func parseDynamicToolCall(from params: [String: Any]) -> CodexDynamicToolCall? {
        guard let threadID = params["threadId"] as? String,
              let turnID = params["turnId"] as? String,
              let callID = params["callId"] as? String,
              let tool = params["tool"] as? String else {
            return nil
        }

        let namespace: String?
        if params["namespace"] is NSNull {
            namespace = nil
        } else {
            namespace = params["namespace"] as? String
        }

        let arguments = params["arguments"] as? [String: Any] ?? [:]
        return CodexDynamicToolCall(
            threadID: threadID,
            turnID: turnID,
            callID: callID,
            namespace: namespace,
            tool: tool,
            arguments: arguments
        )
    }

    private static func parseRealtimeAudioChunk(
        threadID: String,
        rawAudio: [String: Any]
    ) -> CodexRealtimeAudioChunk? {
        guard let base64Audio = rawAudio["data"] as? String,
              let audioData = Data(base64Encoded: base64Audio),
              let sampleRate = numericInt(rawAudio["sampleRate"]),
              let channelCount = numericInt(rawAudio["numChannels"]) else {
            return nil
        }

        return CodexRealtimeAudioChunk(
            threadID: threadID,
            data: audioData,
            sampleRate: sampleRate,
            channelCount: channelCount,
            samplesPerChannel: numericInt(rawAudio["samplesPerChannel"]),
            itemID: rawAudio["itemId"] as? String
        )
    }

    private static func numericInt(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String {
            return Int(string)
        }
        return nil
    }

    private func markActiveTurnComputerUseInvoked() {
        guard var turn = activeTurn else { return }
        turn.invokedComputerUseInteraction = true
        activeTurn = turn
    }

    private func handleNotification(method: String, params: [String: Any]) async {
        switch method {
        case "thread/realtime/started":
            guard let threadID = params["threadId"] as? String,
                  let version = params["version"] as? String else {
                return
            }
            await realtimeEventHandler?(
                .started(
                    threadID: threadID,
                    sessionID: params["sessionId"] as? String,
                    version: version
                )
            )

        case "thread/realtime/outputAudio/delta":
            guard let threadID = params["threadId"] as? String,
                  let rawAudio = params["audio"] as? [String: Any],
                  let audioChunk = Self.parseRealtimeAudioChunk(threadID: threadID, rawAudio: rawAudio) else {
                return
            }
            await realtimeEventHandler?(.outputAudioDelta(audioChunk))

        case "thread/realtime/transcript/delta":
            guard let threadID = params["threadId"] as? String,
                  let role = params["role"] as? String,
                  let delta = params["delta"] as? String else {
                return
            }
            await realtimeEventHandler?(.transcriptDelta(threadID: threadID, role: role, delta: delta))

        case "thread/realtime/transcript/done":
            guard let threadID = params["threadId"] as? String,
                  let role = params["role"] as? String,
                  let text = params["text"] as? String else {
                return
            }
            await realtimeEventHandler?(.transcriptDone(threadID: threadID, role: role, text: text))

        case "thread/realtime/error":
            guard let threadID = params["threadId"] as? String,
                  let message = params["message"] as? String else {
                return
            }
            await realtimeEventHandler?(.error(threadID: threadID, message: message))

        case "thread/realtime/closed":
            guard let threadID = params["threadId"] as? String else {
                return
            }
            await realtimeEventHandler?(.closed(threadID: threadID, reason: params["reason"] as? String))

        case "item/agentMessage/delta":
            guard var activeTurn,
                  let turnID = params["turnId"] as? String,
                  turnID == activeTurn.turnID,
                  let delta = params["delta"] as? String else {
                return
            }

            activeTurn.accumulatedText += delta
            Self.logFirstTextChunkIfNeeded(activeTurn: &activeTurn, notificationName: method)
            self.activeTurn = activeTurn
            await activeTurn.onTextChunk(activeTurn.accumulatedText)

        case "item/completed":
            guard let activeTurn,
                  let turnID = params["turnId"] as? String,
                  turnID == activeTurn.turnID,
                  let item = params["item"] as? [String: Any],
                  let itemType = item["type"] as? String else {
                return
            }

            if itemType == "agentMessage", let text = item["text"] as? String {
                var updatedTurn = activeTurn
                updatedTurn.accumulatedText = text
                Self.logFirstTextChunkIfNeeded(activeTurn: &updatedTurn, notificationName: method)
                self.activeTurn = updatedTurn
                await updatedTurn.onTextChunk(text)
                return
            }

            markActiveTurnComputerUseInvoked()

            let summary = Self.computerUseLogSummaryForCompletedItem(item)
            ClickyMessageLogStore.shared.append(
                lane: "computer-use",
                direction: "event",
                event: "turn.item.completed",
                fields: [
                    "itemType": itemType,
                    "summary": summary
                ]
            )

        case "turn/completed":
            guard let activeTurn,
                  let turn = params["turn"] as? [String: Any],
                  let turnID = turn["id"] as? String,
                  turnID == activeTurn.turnID else {
                return
            }

            self.activeTurn = nil

            let status = turn["status"] as? String ?? "failed"
            if status == "completed" {
                let finalText = activeTurn.accumulatedText
                let completedAt = Date()
                let duration = completedAt.timeIntervalSince(activeTurn.turnStartedAt)
                Self.printTiming(
                    label: activeTurn.debugLogLabel,
                    "turn completed turn=\(Self.formattedLogDuration(duration)) total=\(Self.formattedLogDuration(completedAt.timeIntervalSince(activeTurn.requestStartedAt))) responseChars=\(finalText.count)"
                )
                activeTurn.continuation.resume(returning: (
                    text: finalText,
                    duration: duration,
                    invokedComputerUseInteraction: activeTurn.invokedComputerUseInteraction
                ))
            } else {
                Self.printTiming(
                    label: activeTurn.debugLogLabel,
                    "turn ended status=\(status) total=\(Self.formattedLogDuration(Date().timeIntervalSince(activeTurn.requestStartedAt)))"
                )

                let errorMessage: String
                if let errorObject = turn["error"] as? [String: Any] {
                    errorMessage = errorObject["message"] as? String ?? "Codex turn failed."
                } else if status == "interrupted" {
                    errorMessage = "Codex turn was interrupted."
                } else {
                    errorMessage = "Codex turn failed."
                }

                activeTurn.continuation.resume(throwing: CodexAppServerError.serverError(errorMessage))
            }

        case "warning":
            if let message = params["message"] as? String {
                print("Warning: Codex warning: \(message)")
            }

        case "configWarning":
            if let summary = params["summary"] as? String {
                print("Warning: Codex config warning: \(summary)")
            }

        default:
            break
        }
    }

    private func handleProcessTermination(exitCode: Int32) {
        clearProcessState()

        let error = CodexAppServerError.processExited(exitCode)

        if let activeTurn {
            self.activeTurn = nil
            activeTurn.continuation.resume(throwing: error)
        }

        let pendingRequests = pendingResponses.values
        pendingResponses.removeAll()
        for pendingRequest in pendingRequests {
            pendingRequest.continuation.resume(throwing: error)
        }
    }

    private func tearDownProcess() {
        guard let processContext else {
            clearProcessState()
            return
        }

        processContext.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        processContext.stderrPipe.fileHandleForReading.readabilityHandler = nil
        try? processContext.stdinHandle.close()

        if processContext.process.isRunning {
            processContext.process.terminate()
        }

        clearProcessState()
    }

    private func clearProcessState() {
        processContext?.stdoutPipe.fileHandleForReading.readabilityHandler = nil
        processContext?.stderrPipe.fileHandleForReading.readabilityHandler = nil
        processContext = nil
        activeCodexExecutablePath = nil
        stdoutBuffer = ""
        stderrBuffer = ""
        threadIDsByThreadConfiguration.removeAll()
    }

    private static func appServerArguments(
        computerUseMCPServerConfiguration: ComputerUseMCPServerConfiguration?
    ) -> [String] {
        var arguments = [
            "app-server",
            "--enable", "realtime_conversation",
            "-c", "mcp_servers={}"
        ]

        if let computerUseMCPServerConfiguration {
            arguments.append(contentsOf: [
                "-c", "mcp_servers.computer-use.command=\(tomlString(computerUseMCPServerConfiguration.command))",
                "-c", "mcp_servers.computer-use.args=\(tomlStringArray(computerUseMCPServerConfiguration.args))",
                "-c", "mcp_servers.computer-use.cwd=\(tomlString(computerUseMCPServerConfiguration.cwd))"
            ])
        }

        arguments.append(contentsOf: ["--listen", "stdio://"])
        return arguments
    }

    private static func computerUseMCPServerConfiguration() -> (
        configuration: ComputerUseMCPServerConfiguration?,
        discoveryState: CompanionComputerUseMCPStatus.DiscoveryState
    ) {
        let fileManager = FileManager.default
        guard let codexAppURL = codexAppURL() else {
            return (nil, .missingCodexApp)
        }

        let pluginDirectoryURL = codexAppURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("openai-bundled", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("computer-use", isDirectory: true)

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: pluginDirectoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return (nil, .missingPlugin)
        }

        let mcpConfigURL = pluginDirectoryURL.appendingPathComponent(".mcp.json")
        guard let mcpConfigData = try? Data(contentsOf: mcpConfigURL),
              let mcpConfig = try? JSONSerialization.jsonObject(with: mcpConfigData) as? [String: Any],
              let mcpServers = mcpConfig["mcpServers"] as? [String: Any],
              let computerUseServer = mcpServers["computer-use"] as? [String: Any],
              let command = computerUseServer["command"] as? String else {
            return (nil, .missingMCPConfig)
        }

        let args = computerUseServer["args"] as? [String] ?? []
        let configuredCwd = computerUseServer["cwd"] as? String ?? "."
        let cwdURL = resolvedURL(path: configuredCwd, relativeTo: pluginDirectoryURL)
        let clientExecutableURL = resolvedURL(path: command, relativeTo: cwdURL)

        guard fileManager.isExecutableFile(atPath: clientExecutableURL.path) else {
            return (nil, .missingClientExecutable)
        }

        return (
            ComputerUseMCPServerConfiguration(
                codexAppURL: codexAppURL,
                pluginDirectoryURL: pluginDirectoryURL,
                clientExecutableURL: clientExecutableURL,
                command: command,
                args: args,
                cwd: cwdURL.path
            ),
            .ready
        )
    }

    private static func codexAppURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
    }

    private static func resolvedURL(path: String, relativeTo baseURL: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        return baseURL.appendingPathComponent(path).standardizedFileURL
    }

    static func computerUseApprovalStoreSnapshot() -> CompanionComputerUseApprovalStoreSnapshot {
        let fileManager = FileManager.default
        let groupContainerURL = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Group Containers", isDirectory: true)
            .appendingPathComponent("2DC432GLL2.com.openai.sky.CUAService", isDirectory: true)
        let approvalStoreURL = groupContainerURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Software", isDirectory: true)
            .appendingPathComponent("ComputerUseAppApprovals.json")

        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: groupContainerURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return CompanionComputerUseApprovalStoreSnapshot(fileURL: approvalStoreURL, state: .groupContainerMissing)
        }

        guard fileManager.fileExists(atPath: approvalStoreURL.path) else {
            return CompanionComputerUseApprovalStoreSnapshot(fileURL: approvalStoreURL, state: .storeMissing)
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: approvalStoreURL.path)
            let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
            let modifiedAt = attributes[.modificationDate] as? Date
            return CompanionComputerUseApprovalStoreSnapshot(
                fileURL: approvalStoreURL,
                state: .present(byteCount: byteCount, modifiedAt: modifiedAt)
            )
        } catch {
            return CompanionComputerUseApprovalStoreSnapshot(
                fileURL: approvalStoreURL,
                state: .unreadable(error.localizedDescription)
            )
        }
    }

    private static func tomlString(_ value: String) -> String {
        let escapedValue = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escapedValue)\""
    }

    private static func tomlStringArray(_ values: [String]) -> String {
        "[" + values.map(tomlString).joined(separator: ",") + "]"
    }

    private static func frontmostRegularApplicationSnapshot() async -> FrontmostApplicationSnapshot? {
        await MainActor.run {
            guard let application = NSWorkspace.shared.frontmostApplication,
                  application.activationPolicy == .regular else {
                return nil
            }

            return FrontmostApplicationSnapshot(
                name: application.localizedName,
                bundleIdentifier: application.bundleIdentifier
            )
        }
    }

    private static func elicitation(
        params: [String: Any],
        mentions application: FrontmostApplicationSnapshot
    ) -> Bool {
        let candidates = [
            application.name,
            application.bundleIdentifier
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !candidates.isEmpty else { return false }

        let strings = jsonStringValues(params).map { $0.lowercased() }
        return strings.contains { value in
            candidates.contains { candidate in
                value.contains(candidate)
            }
        }
    }

    private static func acceptedComputerUseElicitationContent(
        from schema: [String: Any],
        for application: FrontmostApplicationSnapshot
    ) -> [String: Any]? {
        guard let properties = schema["properties"] as? [String: Any] else {
            return nil
        }

        let requiredPropertyNames = Set((schema["required"] as? [String]) ?? [])
        var content: [String: Any] = [:]

        for property in properties {
            guard let propertySchema = property.value as? [String: Any],
                  let value = elicitationValue(
                    forPropertyName: property.key,
                    propertySchema: propertySchema,
                    application: application
                  ) else {
                continue
            }
            content[property.key] = value
        }

        for requiredPropertyName in requiredPropertyNames where content[requiredPropertyName] == nil {
            return nil
        }

        return content
    }

    private static func elicitationValue(
        forPropertyName propertyName: String,
        propertySchema: [String: Any],
        application: FrontmostApplicationSnapshot
    ) -> Any? {
        let context = normalizedPropertyContext(propertyName: propertyName, propertySchema: propertySchema)
        let type = propertySchema["type"] as? String

        if isAppIdentifierContext(context), stringOptions(from: propertySchema).isEmpty {
            return application.bundleIdentifier ?? application.name
        }

        switch type {
        case "boolean":
            if isPersistenceContext(context) || isApprovalContext(context) {
                return true
            }
            return propertySchema["default"] as? Bool

        case "string":
            let options = stringOptions(from: propertySchema)
            if !options.isEmpty {
                if isAppIdentifierContext(context),
                   let appOption = preferredAppOption(options: options, application: application) {
                    return appOption
                }
                if isPersistenceContext(context) || isApprovalContext(context),
                   let durableApprovalOption = preferredOption(
                    options: options,
                    preferredTerms: ["always", "permanent", "persistent", "remember"],
                    avoidedTerms: ["deny", "decline", "cancel", "reject"]
                   ) {
                    return durableApprovalOption
                }
                if isPersistenceContext(context),
                   let persistenceOption = preferredOption(
                    options: options,
                    preferredTerms: ["always", "permanent", "persistent", "remember"],
                    avoidedTerms: ["once", "session", "deny", "decline", "cancel"]
                   ) {
                    return persistenceOption
                }
                if let approvalOption = preferredOption(
                    options: options,
                    preferredTerms: ["allow", "approve", "authorized", "authorize", "accept", "yes", "grant"],
                    avoidedTerms: ["deny", "decline", "cancel", "reject"]
                ) {
                    return approvalOption
                }
            }

            if let defaultValue = propertySchema["default"] as? String {
                return defaultValue
            }
            if isAppIdentifierContext(context) {
                return application.bundleIdentifier ?? application.name
            }
            return nil

        case "array":
            guard let items = propertySchema["items"] as? [String: Any] else { return nil }
            let options = stringOptions(from: items)
            guard !options.isEmpty else { return propertySchema["default"] as? [String] }
            if isPersistenceContext(context),
               let persistenceOption = preferredOption(
                options: options,
                preferredTerms: ["always", "permanent", "persistent", "remember"],
                avoidedTerms: ["once", "session", "deny", "decline", "cancel"]
               ) {
                return [persistenceOption]
            }
            return propertySchema["default"] as? [String]

        default:
            return nil
        }
    }

    private static func normalizedPropertyContext(
        propertyName: String,
        propertySchema: [String: Any]
    ) -> String {
        [
            propertyName,
            propertySchema["title"] as? String,
            propertySchema["description"] as? String
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
    }

    private static func isAppIdentifierContext(_ context: String) -> Bool {
        containsAny(context, terms: ["bundle", "bundle identifier", "app name", "application"])
    }

    private static func isPersistenceContext(_ context: String) -> Bool {
        containsAny(context, terms: ["persist", "persistence", "permanent", "always", "remember"])
    }

    private static func isApprovalContext(_ context: String) -> Bool {
        containsAny(context, terms: ["approval", "allow", "authorize", "permission", "access", "use"])
    }

    private static func containsAny(_ value: String, terms: [String]) -> Bool {
        terms.contains { value.contains($0) }
    }

    private static func stringOptions(from schema: [String: Any]) -> [(value: String, label: String)] {
        if let oneOf = schema["oneOf"] as? [[String: Any]] {
            return oneOf.compactMap { option in
                guard let value = option["const"] as? String else { return nil }
                return (value: value, label: option["title"] as? String ?? value)
            }
        }

        if let anyOf = schema["anyOf"] as? [[String: Any]] {
            return anyOf.compactMap { option in
                guard let value = option["const"] as? String else { return nil }
                return (value: value, label: option["title"] as? String ?? value)
            }
        }

        if let enumValues = schema["enum"] as? [String] {
            return enumValues.map { (value: $0, label: $0) }
        }

        return []
    }

    private static func preferredAppOption(
        options: [(value: String, label: String)],
        application: FrontmostApplicationSnapshot
    ) -> String? {
        let candidates = [application.bundleIdentifier, application.name]
            .compactMap { $0?.lowercased() }
            .filter { !$0.isEmpty }

        return options.first { option in
            let optionText = "\(option.value) \(option.label)".lowercased()
            return candidates.contains { optionText.contains($0) }
        }?.value
    }

    private static func preferredOption(
        options: [(value: String, label: String)],
        preferredTerms: [String],
        avoidedTerms: [String]
    ) -> String? {
        if let preferredOption = options.first(where: { option in
            let optionText = "\(option.value) \(option.label)".lowercased()
            return preferredTerms.contains { optionText.contains($0) }
        }) {
            return preferredOption.value
        }

        return options.first { option in
            let optionText = "\(option.value) \(option.label)".lowercased()
            return !avoidedTerms.contains { optionText.contains($0) }
        }?.value
    }

    private static func contentRequestsPersistence(_ content: [String: Any]) -> Bool {
        content.contains { element in
            let keyContext = element.key.lowercased()
            let value = element.value
            if isPersistenceContext(keyContext), let boolValue = value as? Bool {
                return boolValue
            }
            if isPersistenceContext(keyContext), let stringValue = value as? String {
                return containsAny(
                    stringValue.lowercased(),
                    terms: ["always", "permanent", "persistent", "remember"]
                )
            }
            if let stringValue = value as? String {
                return containsAny(
                    stringValue.lowercased(),
                    terms: ["always", "permanent", "persistent", "remember"]
                )
            }
            if let stringValues = value as? [String] {
                return stringValues.contains { stringValue in
                    containsAny(
                        stringValue.lowercased(),
                        terms: ["always", "permanent", "persistent", "remember"]
                    )
                }
            }
            return false
        }
    }

    private static func jsonStringValues(_ value: Any) -> [String] {
        if let string = value as? String {
            return [string]
        }

        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { element in
                [element.key] + jsonStringValues(element.value)
            }
        }

        if let array = value as? [Any] {
            return array.flatMap(jsonStringValues)
        }

        return []
    }

    private static func parseAccountSnapshot(from result: [String: Any]) -> CodexAccountSnapshot {
        let requiresOpenAIAuthentication = result["requiresOpenaiAuth"] as? Bool ?? true
        let account = result["account"] as? [String: Any]

        return CodexAccountSnapshot(
            requiresOpenAIAuthentication: requiresOpenAIAuthentication,
            authMode: account?["type"] as? String,
            planType: account?["planType"] as? String
        )
    }

    private static func parseModelOptions(from result: [String: Any]) -> [CodexModelOption] {
        guard let rawModels = result["data"] as? [[String: Any]] else {
            return []
        }

        return rawModels.compactMap { rawModel in
            guard let modelID = rawModel["model"] as? String,
                  let displayName = rawModel["displayName"] as? String else {
                return nil
            }

            return CodexModelOption(
                id: modelID,
                displayName: displayName,
                isDefault: rawModel["isDefault"] as? Bool ?? false,
                supportedReasoningEfforts: parseReasoningEffortOptions(from: rawModel),
                defaultReasoningEffort: rawModel["defaultReasoningEffort"] as? String,
                additionalSpeedTiers: rawModel["additionalSpeedTiers"] as? [String] ?? []
            )
        }
    }

    private static func parseRealtimeVoiceConfiguration(from result: [String: Any]) throws -> CodexRealtimeVoiceConfiguration {
        let voicesObject = result["voices"] as? [String: Any] ?? result
        let v1Voices = voicesObject["v1"] as? [String] ?? []
        let v2Voices = voicesObject["v2"] as? [String] ?? []
        let defaultV2Voice = voicesObject["defaultV2"] as? String
        let defaultV1Voice = voicesObject["defaultV1"] as? String
        let defaultVoiceID = defaultV2Voice ?? defaultV1Voice

        let v2Options = v2Voices.map { voiceID in
            CodexRealtimeVoiceOption(
                id: voiceID,
                displayName: displayName(forRealtimeVoice: voiceID, generation: "V2"),
                generation: "v2",
                isDefault: voiceID == defaultVoiceID
            )
        }
        let v1Options = v1Voices.map { voiceID in
            CodexRealtimeVoiceOption(
                id: voiceID,
                displayName: displayName(forRealtimeVoice: voiceID, generation: "V1"),
                generation: "v1",
                isDefault: voiceID == defaultVoiceID
            )
        }

        let options = v2Options + v1Options.filter { v1Option in
            !v2Options.contains(where: { $0.id == v1Option.id })
        }

        return CodexRealtimeVoiceConfiguration(
            options: options,
            defaultVoiceID: defaultVoiceID
        )
    }

    private static func parseReasoningEffortOptions(from rawModel: [String: Any]) -> [CodexReasoningEffortOption] {
        guard let rawReasoningEfforts = rawModel["supportedReasoningEfforts"] as? [[String: Any]] else {
            return []
        }

        return rawReasoningEfforts.compactMap { rawReasoningEffort in
            guard let reasoningEffort = rawReasoningEffort["reasoningEffort"] as? String else {
                return nil
            }

            return CodexReasoningEffortOption(
                id: reasoningEffort,
                displayName: displayName(forReasoningEffort: reasoningEffort),
                description: rawReasoningEffort["description"] as? String ?? ""
            )
        }
    }

    private static func displayName(forRealtimeVoice voiceID: String, generation: String) -> String {
        let spaced = voiceID
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { word in
                word.prefix(1).uppercased() + word.dropFirst()
            }
            .joined(separator: " ")
        return "\(spaced) \(generation)"
    }

    private static func displayName(forReasoningEffort reasoningEffort: String) -> String {
        switch reasoningEffort {
        case "none":
            return "None"
        case "minimal":
            return "Minimal"
        case "low":
            return "Low"
        case "medium":
            return "Medium"
        case "high":
            return "High"
        case "xhigh":
            return "Extra High"
        default:
            return reasoningEffort
        }
    }

    private static func parseRequestID(from value: Any?) -> Int? {
        if let number = value as? NSNumber {
            return number.intValue
        }

        if let string = value as? String {
            return Int(string)
        }

        return nil
    }

    private static func writeTemporaryImages(images: [(data: Data, label: String)]) throws -> [URL] {
        let clickyTemporaryImageDirectoryURL = try temporaryImageDirectoryURL()

        return try images.map { image in
            let fileExtension = fileExtensionForImageData(image.data)
            let fileURL = clickyTemporaryImageDirectoryURL
                .appendingPathComponent("clicky-codex-\(UUID().uuidString)")
                .appendingPathExtension(fileExtension)
            try image.data.write(to: fileURL, options: .atomic)
            return fileURL
        }
    }

    private static func removeTemporaryFiles(at fileURLs: [URL]) {
        for fileURL in fileURLs {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func fileExtensionForImageData(_ imageData: Data) -> String {
        if imageData.count >= 4 {
            let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47]
            let firstFourBytes = [UInt8](imageData.prefix(4))
            if firstFourBytes == pngSignature {
                return "png"
            }
        }

        return "jpg"
    }

    private static func appServerWorkingDirectoryURL() throws -> URL {
        let workingDirectoryURL = try applicationSupportDirectoryURL()
            .appendingPathComponent("CodexAppServer", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectoryURL,
            withIntermediateDirectories: true
        )
        return workingDirectoryURL
    }

    private static func temporaryImageDirectoryURL() throws -> URL {
        let temporaryImageDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClickyCodexImages", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryImageDirectoryURL,
            withIntermediateDirectories: true
        )
        return temporaryImageDirectoryURL
    }

    private static func applicationSupportDirectoryURL() throws -> URL {
        let applicationSupportDirectoryURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "Clicky"
        return applicationSupportDirectoryURL.appendingPathComponent(bundleIdentifier, isDirectory: true)
    }

    private static func resolveCodexExecutableURL() throws -> URL {
        if let configuredPath = AppBundleConfiguration.stringValue(forKey: "CodexCLIPath") {
            if FileManager.default.isExecutableFile(atPath: configuredPath) {
                return URL(fileURLWithPath: configuredPath)
            }
            throw CodexAppServerError.invalidCodexExecutablePath(configuredPath)
        }

        if let bundledCodexURL = Bundle.main.url(forResource: "codex", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: bundledCodexURL.path) {
            return bundledCodexURL
        }

        if let bundledCodexURL = Bundle.main.resourceURL?
            .appendingPathComponent("codex-app-server")
            .appendingPathComponent("codex"),
           FileManager.default.isExecutableFile(atPath: bundledCodexURL.path) {
            return bundledCodexURL
        }

        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        let candidatePaths = [
            "\(homeDirectoryPath)/Library/pnpm/codex",
            "\(homeDirectoryPath)/.volta/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ] + (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map { "\($0)/codex" }

        for candidatePath in candidatePaths {
            if FileManager.default.isExecutableFile(atPath: candidatePath) {
                return URL(fileURLWithPath: candidatePath)
            }
        }

        throw CodexAppServerError.codexExecutableNotFound
    }

    private static func processEnvironment(for codexExecutableURL: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let homeDirectoryPath = FileManager.default.homeDirectoryForCurrentUser.path
        let codexDirectoryPath = codexExecutableURL.deletingLastPathComponent().path
        let nodeDirectoryPaths = nodeExecutableDirectoryPaths(homeDirectoryPath: homeDirectoryPath)
        let existingPathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        let pathEntries = [
            codexDirectoryPath,
            "\(homeDirectoryPath)/Library/pnpm",
        ] + nodeDirectoryPaths + [
            "\(homeDirectoryPath)/.vite-plus/bin",
            "\(homeDirectoryPath)/.volta/bin",
            "\(homeDirectoryPath)/.local/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ] + existingPathEntries

        environment["PATH"] = Array(NSOrderedSet(array: pathEntries)).compactMap { $0 as? String }.joined(separator: ":")
        environment["PNPM_HOME"] = environment["PNPM_HOME"] ?? "\(homeDirectoryPath)/Library/pnpm"
        environment["HOME"] = environment["HOME"] ?? homeDirectoryPath

        return environment
    }

    private static func nodeExecutableDirectoryPaths(homeDirectoryPath: String) -> [String] {
        let fileManager = FileManager.default
        let homeDirectoryURL = URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
        var candidateDirectoryURLs = [
            homeDirectoryURL.appendingPathComponent("Library/pnpm", isDirectory: true),
            homeDirectoryURL.appendingPathComponent(".local/share/fnm/aliases/default/bin", isDirectory: true),
            homeDirectoryURL.appendingPathComponent(".local/share/fnm/aliases/lts-latest/bin", isDirectory: true)
        ]

        let fnmMultishellsDirectoryURL = homeDirectoryURL.appendingPathComponent(".local/state/fnm_multishells", isDirectory: true)
        candidateDirectoryURLs.append(contentsOf: childDirectoryURLs(at: fnmMultishellsDirectoryURL).map {
            $0.appendingPathComponent("bin", isDirectory: true)
        })

        let fnmNodeVersionsDirectoryURL = homeDirectoryURL.appendingPathComponent(".local/share/fnm/node-versions", isDirectory: true)
        candidateDirectoryURLs.append(contentsOf: childDirectoryURLs(at: fnmNodeVersionsDirectoryURL)
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedDescending
            }
            .map {
                $0.appendingPathComponent("installation/bin", isDirectory: true)
            })

        let nvmNodeVersionsDirectoryURL = homeDirectoryURL.appendingPathComponent(".nvm/versions/node", isDirectory: true)
        candidateDirectoryURLs.append(contentsOf: childDirectoryURLs(at: nvmNodeVersionsDirectoryURL)
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedDescending
            }
            .map {
                $0.appendingPathComponent("bin", isDirectory: true)
            })

        let paths = candidateDirectoryURLs
            .map { $0.standardizedFileURL.path }
            .filter { directoryPath in
                fileManager.isExecutableFile(atPath: URL(fileURLWithPath: directoryPath, isDirectory: true).appendingPathComponent("node").path)
            }

        return Array(NSOrderedSet(array: paths)).compactMap { $0 as? String }
    }

    private static func childDirectoryURLs(at directoryURL: URL) -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ).filter { childURL in
                var isDirectory: ObjCBool = false
                return FileManager.default.fileExists(atPath: childURL.path, isDirectory: &isDirectory) && isDirectory.boolValue
            }
        } catch {
            return []
        }
    }

    private static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
