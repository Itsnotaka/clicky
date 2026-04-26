//
//  CodexAppServerClient.swift
//  Codex app-server bridge used for streaming multimodal Clicky responses.
//

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
        let continuation: CheckedContinuation<(text: String, duration: TimeInterval), Error>
        var accumulatedText: String
        var hasLoggedFirstTextChunk: Bool
    }

    private struct PendingRequest {
        let method: String
        let continuation: CheckedContinuation<Any, Error>
    }

    private let session = URLSession(configuration: .default)
    private var processContext: ProcessContext?
    private var startupTask: Task<Void, Error>?
    private var pendingResponses: [Int: PendingRequest] = [:]
    private var nextRequestID = 1
    private var activeTurn: ActiveTurn?
    private var threadIDsByThreadConfiguration: [String: String] = [:]
    private var activeCodexExecutablePath: String?
    private var stdoutBuffer = ""
    private var stderrBuffer = ""
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

    func analyzeImageStreaming(
        images: [(data: Data, label: String)],
        developerInstructions: String,
        userPrompt: String,
        model: String,
        reasoningEffort: String?,
        serviceTier: String?,
        debugLogLabel: String? = nil,
        onTextChunk: @escaping @MainActor @Sendable (String) -> Void
    ) async throws -> (text: String, duration: TimeInterval) {
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
                hasLoggedFirstTextChunk: false
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

        return try await withCheckedThrowingContinuation { continuation in
            activeTurn = ActiveTurn(
                turnID: turnID,
                requestStartedAt: requestStartedAt,
                turnStartedAt: Date(),
                debugLogLabel: debugLogLabel,
                onTextChunk: onTextChunk,
                continuation: continuation,
                accumulatedText: "",
                hasLoggedFirstTextChunk: false
            )
        }
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
        // Clicky owns its app-server tool surface; user-level MCP servers can be noisy or unavailable.
        process.arguments = [
            "app-server",
            "-c", "mcp_servers={}",
            "--listen", "stdio://"
        ]
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
        serviceTier: String?
    ) async throws -> String {
        let threadConfigurationKey = model + "\n" + (serviceTier ?? "standard") + "\n" + developerInstructions
        if let existingThreadID = threadIDsByThreadConfiguration[threadConfigurationKey] {
            return existingThreadID
        }

        var threadParams: [String: Any] = [
            "model": model,
            "approvalPolicy": "never",
            "serviceName": "clicky",
            "developerInstructions": developerInstructions,
            "personality": "friendly",
            "ephemeral": true,
            "experimentalRawEvents": false,
            "persistExtendedHistory": false
        ]
        threadParams["serviceTier"] = Self.serviceTierParameterValue(serviceTier)

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

    private func handleNotification(method: String, params: [String: Any]) async {
        switch method {
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
            guard var activeTurn,
                  let turnID = params["turnId"] as? String,
                  turnID == activeTurn.turnID,
                  let item = params["item"] as? [String: Any],
                  let itemType = item["type"] as? String,
                  itemType == "agentMessage",
                  let text = item["text"] as? String else {
                return
            }

            activeTurn.accumulatedText = text
            Self.logFirstTextChunkIfNeeded(activeTurn: &activeTurn, notificationName: method)
            self.activeTurn = activeTurn
            await activeTurn.onTextChunk(text)

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
                activeTurn.continuation.resume(returning: (text: finalText, duration: duration))
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
        let existingPathEntries = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        let pathEntries = [
            codexDirectoryPath,
            "\(homeDirectoryPath)/Library/pnpm",
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

    private static var clientVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
