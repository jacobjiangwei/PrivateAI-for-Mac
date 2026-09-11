import AppKit
import Foundation
import LLMCore
import Observation
import PrivateAITools

@MainActor
@Observable
final class ChatCoordinator {
    private(set) var conversations: [ConversationRecord] = []
    private(set) var selectedConversation: ConversationRecord?
    private(set) var isGenerating = false
    private(set) var activity = ""
    private(set) var transcriptRevision = 0
    private(set) var generationMetrics = GenerationMetrics()
    private(set) var composerFocusRequest = 0
    private(set) var warmupState = "Not started"
    private(set) var warmupElapsedSeconds: Double?
    private(set) var warmupPrefixTokens: Int?
    private(set) var pendingAttachments: [ImportedArtifact] = []
    private(set) var isImportingAttachments = false
    private(set) var attachmentError: String?
    private(set) var executionWorkspace: URL?
    private(set) var terminalActivity: TerminalActivityState?
    private(set) var terminalAvailable: Bool
    let browser: BrowserCoordinator
    var draft = ""

    let ollama: OllamaServiceController

    private let database: ConversationDatabase
    private let modelTraceTranscript: ModelTraceTranscript
    private var warmupTraceEvents: [ModelTraceEvent] = []
    private var currentAssistantID: UUID?
    private let agent: ChatAgent
    private let log: RuntimeLog
    private let artifactStore: ManagedArtifactStore
    private let defaultExecutionWorkspace: URL?
    private var generationTask: Task<Void, Never>?
    private var activeGenerationConversationID: UUID?
    private var attachmentImportTask: Task<Void, Never>?
    private var pendingToolMessages: [(id: UUID, name: String, arguments: [String: JSONValue])] = []
    private var thinkingMessageID: UUID?

    init(dependencies: AppDependencies) {
        database = dependencies.database
        modelTraceTranscript = ModelTraceTranscript(database: dependencies.database)
        agent = dependencies.agent
        log = dependencies.runtimeLog
        artifactStore = dependencies.artifactStore
        defaultExecutionWorkspace = dependencies.initialExecutionWorkspace
        executionWorkspace = dependencies.initialExecutionWorkspace
        terminalAvailable = dependencies.terminalBackend != nil
        browser = dependencies.browser
        ollama = dependencies.ollama
        reloadConversations()
        Task {
            await ollama.refresh()
            await openBrowserPreviewIfConfigured()
            await warmSelectedModel()
            await runAcceptanceScenarioIfConfigured()
        }
    }

    var messages: [MessageRecord] {
        selectedConversation?.messages.sorted { $0.sequence < $1.sequence } ?? []
    }

    var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !ollama.selectedModel.isEmpty
            && ollama.state.isReady
            && !isGenerating
            && !isImportingAttachments
    }

    var usesCustomExecutionWorkspace: Bool {
        executionWorkspace?.standardizedFileURL.path
            != defaultExecutionWorkspace?.standardizedFileURL.path
    }

    var executionWorkspaceLabel: String {
        usesCustomExecutionWorkspace
            ? executionWorkspace?.lastPathComponent ?? "Workspace"
            : "PrivateAI Workspace"
    }

    func newConversation() {
        do {
            selectedConversation = try database.createConversation(modelName: ollama.selectedModel)
            reloadConversations(preservingSelection: true)
            composerFocusRequest += 1
        } catch {
            activity = error.localizedDescription
        }
    }

    func selectConversation(id: UUID) {
        selectedConversation = conversations.first { $0.id == id }
        composerFocusRequest += 1
    }

    func deleteConversation(_ conversation: ConversationRecord) {
        guard activeGenerationConversationID != conversation.id else { return }
        do {
            try database.delete(conversation)
            if selectedConversation?.id == conversation.id {
                selectedConversation = nil
            }
            reloadConversations()
            Task { await reconcileArtifacts() }
        } catch {
            activity = error.localizedDescription
        }
    }

    func chooseAttachments() {
        guard !isGenerating, !isImportingAttachments else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.resolvesAliases = true
        panel.allowedContentTypes = LocalDocumentFormat.supportedContentTypes
        panel.message = "Choose up to \(ManagedArtifactStore.maximumFilesPerImport) local documents"
        guard panel.runModal() == .OK else { return }
        _ = importAttachments(from: panel.urls)
    }

    func chooseExecutionWorkspace() {
        guard terminalAvailable, !isGenerating, !isImportingAttachments else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        panel.message = "Choose the folder PrivateAI may use for terminal work"
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        executionWorkspace = selected.standardizedFileURL.resolvingSymlinksInPath()
    }

    func clearExecutionWorkspace() {
        guard !isGenerating else { return }
        executionWorkspace = defaultExecutionWorkspace
    }

    @discardableResult
    func importAttachments(from urls: [URL]) -> Bool {
        guard !urls.isEmpty, !isGenerating, !isImportingAttachments else { return false }
        let remainingCapacity = ManagedArtifactStore.maximumFilesPerImport - pendingAttachments.count
        guard urls.count <= remainingCapacity else {
            attachmentError = ManagedArtifactStoreError
                .tooManyFiles(ManagedArtifactStore.maximumFilesPerImport)
                .localizedDescription
            return false
        }
        isImportingAttachments = true
        attachmentError = nil
        attachmentImportTask = Task { [weak self] in
            guard let self else { return }
            var imported: [ImportedArtifact] = []
            do {
                imported = try await artifactStore.importFiles(from: urls)
                try Task.checkCancellation()
                var seenKeys = Set(pendingAttachments.map(\.storageKey))
                for attachment in imported where seenKeys.insert(attachment.storageKey).inserted {
                    pendingAttachments.append(attachment)
                }
                let duplicates = imported.filter { attachment in
                    self.pendingAttachments.contains { $0.id == attachment.id } == false
                }
                await artifactStore.release(duplicates)
            } catch is CancellationError {
                await artifactStore.release(imported)
            } catch {
                attachmentError = error.localizedDescription
            }
            isImportingAttachments = false
            attachmentImportTask = nil
        }
        return true
    }

    func removePendingAttachment(id: UUID) {
        let removed = pendingAttachments.filter { $0.id == id }
        pendingAttachments.removeAll { $0.id == id }
        attachmentError = nil
        Task {
            await artifactStore.release(removed)
            await reconcileArtifacts()
        }
    }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, canSend else { return }

        do {
            let conversation = try selectedConversation
                ?? database.createConversation(modelName: ollama.selectedModel)
            selectedConversation = conversation
            conversation.modelName = ollama.selectedModel
            let priorUserPrompts = conversation.messages.compactMap { message in
                message.role == .user ? message.content : nil
            }
            let authorizedLocalFiles = PromptLocalFileResolver.files(
                in: [prompt] + priorUserPrompts.reversed()
            )
            let hasDocumentToolHistory = DocumentConversationPolicy.hasDocumentToolHistory(
                toolNames: conversation.messages.compactMap(\.toolName)
            )
            let history = Self.modelHistory(for: conversation)
            let turn = try database.appendUserTurn(
                to: conversation,
                prompt: prompt,
                attachments: pendingAttachments,
                containsLocalDocumentReference: !authorizedLocalFiles.isEmpty
            )
            let sentAttachments = pendingAttachments
            let modelPrompt = AttachmentModelContentBuilder.content(for: turn.user)
            let assistant = turn.assistant
            currentAssistantID = assistant.id
            for event in warmupTraceEvents {
                try modelTraceTranscript.consume(event, in: conversation, before: assistant)
            }
            warmupTraceEvents.removeAll()
            let hasManagedAttachments = conversation.messages.contains {
                !$0.attachments.isEmpty
            }
            let documentPrivacyMode = hasManagedAttachments
                || hasDocumentToolHistory
                || !authorizedLocalFiles.isEmpty
            draft = ""
            pendingAttachments = []
            Task { await artifactStore.release(sentAttachments) }
            attachmentError = nil
            isGenerating = true
            terminalActivity = nil
            pendingToolMessages = []
            thinkingMessageID = nil
            generationMetrics.start()
            activity = "Preparing request"
            Task {
                await log.record("chat.generation.started", fields: [
                    "conversation_id": conversation.id.uuidString,
                    "model": conversation.modelName
                ])
            }
            reloadConversations(preservingSelection: true)
            let assistantID = assistant.id
            let conversationID = conversation.id
            let modelName = conversation.modelName
            let runID = UUID()
            activeGenerationConversationID = conversationID

            generationTask = Task { [weak self] in
                guard let self else { return }
                await log.record(
                    "run.started",
                    category: "agent",
                    runID: runID,
                    conversationID: conversationID,
                    data: [
                        "history_message_count": history.count,
                        "model": modelName,
                        "prompt_characters": prompt.count,
                        "attachment_count": turn.user.attachments.count,
                        "authorized_local_file_count": authorizedLocalFiles.count,
                        "system_prompt_version": LLMCoreSystemPrompt.version
                    ]
                )
                do {
                    let result = try await agent.respond(
                        prompt: modelPrompt,
                        history: history,
                        model: modelName,
                        runID: runID,
                        conversationID: conversationID,
                        documentPrivacyMode: documentPrivacyMode,
                        executionWorkspace: executionWorkspace,
                        managedAttachmentAccess: hasManagedAttachments,
                        authorizedLocalFiles: authorizedLocalFiles,
                    ) { event in
                        await self.consume(
                            event,
                            assistantID: assistantID,
                            conversationID: conversationID,
                            runID: runID,
                            model: modelName,
                            documentPrivacyMode: documentPrivacyMode
                        )
                    }
                    let finalAssistant = conversation.messages.first { $0.id == self.currentAssistantID } ?? assistant
                    try database.update(finalAssistant, content: result.text, status: .complete)
                    generationMetrics.finish(performance: result.performance)
                    await log.record("chat.generation.finished", fields: [
                        "conversation_id": conversationID.uuidString,
                        "tokens_per_second": String(generationMetrics.finalTokensPerSecond ?? 0),
                        "ttft_seconds": String(generationMetrics.ttftSeconds ?? 0)
                    ])
                    await log.record(
                        "run.finished",
                        category: "agent",
                        runID: runID,
                        conversationID: conversationID,
                        data: [
                            "answer_characters": result.text.count,
                            "model_request_count": result.performance.modelRequestCount,
                            "output_token_count": result.performance.modelUsage.reduce(0) {
                                $0 + ($1.outputTokenCount ?? 0)
                            },
                            "time_to_first_event_seconds": jsonNumber(result.performance.timeToFirstEventSeconds),
                            "time_to_first_text_seconds": jsonNumber(result.performance.timeToFirstTextSeconds),
                            "tokens_per_second": jsonNumber(generationMetrics.finalTokensPerSecond),
                            "tool_call_count": result.performance.toolCallCount,
                            "total_seconds": result.performance.totalSeconds
                        ]
                    )
                    transcriptRevision += 1
                    activity = ""
                } catch is CancellationError {
                    generationMetrics.stop()
                    try? database.update(
                        conversation.messages.first { $0.id == self.currentAssistantID } ?? assistant,
                        status: .interrupted,
                        errorMessage: "Generation stopped."
                    )
                    transcriptRevision += 1
                    activity = "Stopped"
                    await log.record("chat.generation.cancelled", fields: [
                        "conversation_id": conversationID.uuidString
                    ])
                    await log.record(
                        "run.cancelled",
                        level: "warning",
                        category: "agent",
                        runID: runID,
                        conversationID: conversationID
                    )
                } catch {
                    generationMetrics.stop()
                    try? database.update(
                        conversation.messages.first { $0.id == self.currentAssistantID } ?? assistant,
                        status: .failed,
                        errorMessage: error.localizedDescription
                    )
                    transcriptRevision += 1
                    activity = error.localizedDescription
                    await log.record("chat.generation.failed", fields: [
                        "conversation_id": conversationID.uuidString,
                        "error": String(describing: error)
                    ])
                    await log.record(
                        "run.failed",
                        level: "error",
                        category: "agent",
                        runID: runID,
                        conversationID: conversationID,
                        data: ["error": String(describing: error)]
                    )
                }
                completeThinkingMessage(in: conversation)
                let finalStatus = conversation.messages.first { $0.id == self.currentAssistantID }?.status ?? .failed
                try? modelTraceTranscript.finish(in: conversation, status: finalStatus)
                for message in conversation.messages where message.status == .streaming {
                    try? database.update(message, status: finalStatus == .complete ? .interrupted : finalStatus)
                }
                isGenerating = false
                if activeGenerationConversationID == conversationID {
                    activeGenerationConversationID = nil
                }
                generationTask = nil
                reloadConversations(preservingSelection: true)
            }
        } catch {
            activity = error.localizedDescription
        }
    }

    func stop() {
        generationTask?.cancel()
    }

    func selectModel(_ model: String) {
        ollama.selectedModel = model
        warmupState = "Not started"
        warmupElapsedSeconds = nil
        warmupPrefixTokens = nil
        Task { await warmSelectedModel() }
    }

    func copyMessage(id: UUID) {
        guard let message = messages.first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
    }

    private func openBrowserPreviewIfConfigured() async {
        #if DEBUG
        guard let value = ProcessInfo.processInfo.environment[
            "PRIVATEAI_BROWSER_PREVIEW_URL"
        ], let url = URL(string: value) else {
            return
        }
        do {
            _ = try await browser.execute(.open(url))
        } catch {
            activity = error.localizedDescription
        }
        #endif
    }

    private func consume(
        _ event: AgentEvent,
        assistantID: UUID,
        conversationID: UUID,
        runID: UUID,
        model: String,
        documentPrivacyMode: Bool
    ) async {
        guard let conversation = conversations.first(where: { $0.id == conversationID }),
              let assistant = conversation.messages.first(where: { $0.id == (currentAssistantID ?? assistantID) })
        else {
            return
        }
        switch event {
        case .modelTrace(let trace):
            if case .request(let request) = trace {
                generationMetrics.recordRequest(request)
            }
            if case .output(let id, let output, let date) = trace,
               let purpose = modelTraceTranscript.purpose(for: id), !purpose.isWarmup {
                switch output {
                case .thinking(let text): generationMetrics.recordThinking(text, at: date)
                case .text(let text):
                    let isAnswer: Bool
                    if case .conversation = purpose { isAnswer = true } else { isAnswer = false }
                    generationMetrics.recordText(text, at: date, isAnswer: isAnswer)
                case .completed(let usage): generationMetrics.recordUsage(usage)
                case .toolCalls: break
                }
            }
            do {
                try modelTraceTranscript.consume(trace, in: conversation, before: assistant)
            } catch {
                activity = "Could not save model trace: \(error.localizedDescription)"
            }
            transcriptRevision += 1
        case .modelRequestStarted(let round):
            activity = "Waiting for model"
            completeThinkingMessage(in: conversation)
            thinkingMessageID = nil
            if round > 0, !assistant.content.isEmpty {
                assistant.role = .modelOutput
                try? database.update(assistant, status: .complete)
                let next = try? database.appendMessage(
                    to: conversation, role: .assistant, content: "", status: .streaming
                )
                currentAssistantID = next?.id ?? assistant.id
            }
            await log.record(
                "model.request.started",
                category: "model",
                runID: runID,
                conversationID: conversationID,
                round: round,
                data: ["model": model]
            )
        case .modelRequestFinished(let round, let usage):
            await log.record(
                "model.request.finished",
                category: "model",
                runID: runID,
                conversationID: conversationID,
                round: round,
                data: usageData(usage)
            )
        case .thinking(let delta):
            activity = "Thinking"
            let thinkingMessage: MessageRecord?
            if let thinkingMessageID {
                thinkingMessage = conversation.messages.first { $0.id == thinkingMessageID }
            } else {
                thinkingMessage = try? database.appendMessage(
                    to: conversation,
                    role: .thinking,
                    content: "",
                    status: .streaming
                )
                thinkingMessageID = thinkingMessage?.id
                try? database.moveToEnd(assistant)
            }
            if let thinkingMessage {
                database.appendStreamingContent(delta, to: thinkingMessage)
                transcriptRevision += 1
            }
        case .text(let delta):
            completeThinkingMessage(in: conversation)
            let isFirstText = assistant.content.isEmpty
            database.appendStreamingContent(delta, to: assistant)
            transcriptRevision += 1
            activity = "Responding"
            if isFirstText {
                await log.record(
                    "model.text.first",
                    category: "model",
                    runID: runID,
                    conversationID: conversationID,
                    data: ["characters": delta.count]
                )
            }
        case .toolCallsProposed(let round, let calls):
            completeThinkingMessage(in: conversation)
            for call in calls {
                _ = try? database.appendMessage(
                    to: conversation,
                    role: .toolCall,
                    content: encodedJSON(.object(call.function.arguments)),
                    status: .complete,
                    toolName: call.function.name
                )
            }
            try? database.moveToEnd(assistant)
            transcriptRevision += 1
            await log.record(
                "model.tool_calls.proposed",
                category: "model",
                runID: runID,
                conversationID: conversationID,
                round: round,
                data: ["calls": calls.map {
                    toolCallData($0, documentPrivacyMode: documentPrivacyMode)
                }]
            )
        case .toolStarted(let name, let arguments):
            completeThinkingMessage(in: conversation)
            activity = "Using \(name)"
            if name == "terminal" {
                startTerminalActivity(arguments: arguments)
            }
            if let toolMessage = try? database.appendMessage(
                to: conversation,
                role: .toolResult,
                content: "",
                status: .streaming,
                toolName: name
            ) {
                pendingToolMessages.append((id: toolMessage.id, name: name, arguments: arguments))
                try? database.moveToEnd(assistant)
                transcriptRevision += 1
            }
            let safeArguments = ToolTranscriptContent.safeArguments(
                name: name,
                arguments: arguments,
                documentPrivacyMode: documentPrivacyMode
            )
            await log.record("tool.started", fields: [
                "action": safeArguments["action"]?.stringValue ?? "",
                "conversation_id": conversationID.uuidString,
                "tool": name
            ])
            await log.record(
                "tool.execution.started",
                category: "tool",
                runID: runID,
                conversationID: conversationID,
                data: [
                    "arguments": jsonObject(.object(safeArguments)),
                    "name": name
                ]
            )
        case .toolProgress(_, let detail):
            activity = detail
        case .toolFinished(let execution):
            if execution.name == "terminal" {
                finishTerminalActivity(execution)
            }
            if let index = pendingToolMessages.firstIndex(where: {
                $0.name == execution.name && $0.arguments == execution.arguments
            }) {
                let toolMessageID = pendingToolMessages.remove(at: index).id
                if let toolMessage = conversation.messages.first(where: { $0.id == toolMessageID }) {
                    try? database.update(
                        toolMessage,
                        content: execution.content,
                        status: execution.succeeded ? .complete : .failed,
                        errorMessage: execution.succeeded ? nil : "Tool execution failed."
                    )
                }
            }
            transcriptRevision += 1
            activity = execution.succeeded ? "Reading tool result" : "Tool failed"
            await log.record("tool.finished", fields: [
                "conversation_id": conversationID.uuidString,
                "succeeded": String(execution.succeeded),
                "tool": execution.name
            ])
            await log.record(
                "tool.execution.finished",
                level: execution.succeeded ? "info" : "error",
                category: "tool",
                runID: runID,
                conversationID: conversationID,
                data: [
                    "arguments": jsonObject(.object(ToolTranscriptContent.safeArguments(
                        name: execution.name,
                        arguments: execution.arguments,
                        documentPrivacyMode: documentPrivacyMode
                    ))),
                    "error_type": execution.errorType ?? "",
                    "name": execution.name,
                    "output_characters": execution.content.count,
                    "succeeded": execution.succeeded
                ]
            )
        case .contextTrimmed(let dropped, let before, let after):
            await log.record(
                "context.trimmed",
                level: "warning",
                category: "model",
                runID: runID,
                conversationID: conversationID,
                data: [
                    "dropped_messages": dropped,
                    "approx_bytes_before": before,
                    "approx_bytes_after": after
                ]
            )
        }
    }

    private func completeThinkingMessage(in conversation: ConversationRecord) {
        guard let thinkingMessageID,
              let thinkingMessage = conversation.messages.first(where: { $0.id == thinkingMessageID }),
              thinkingMessage.status == .streaming
        else {
            return
        }
        try? database.update(thinkingMessage, status: .complete)
        transcriptRevision += 1
    }

    private func startTerminalActivity(arguments: [String: JSONValue]) {
        let action = arguments["action"]?.stringValue ?? "run"
        let existing = terminalActivity
        let status = switch action {
        case "wait": "Waiting for checkpoint"
        case "stop": "Stopping"
        default: "Running"
        }
        terminalActivity = TerminalActivityState(
            command: arguments["command"]?.stringValue ?? existing?.command ?? "",
            workingDirectory: arguments["working_directory"]?.stringValue
                ?? existing?.workingDirectory
                ?? executionWorkspace?.path
                ?? "",
            status: status,
            startedAt: action == "run" ? .now : existing?.startedAt ?? .now,
            observedElapsedSeconds: existing?.observedElapsedSeconds ?? 0,
            latestOutput: existing?.latestOutput,
            isActive: true
        )
    }

    private func finishTerminalActivity(_ execution: ToolExecution) {
        guard execution.succeeded,
              let data = execution.content.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue else {
            terminalActivity?.status = "Failed"
            terminalActivity?.isActive = false
            return
        }
        let status = object["status"]?.stringValue ?? "failed"
        let elapsed: Double = if case .number(let value) = object["elapsed_seconds"] {
            value
        } else {
            terminalActivity?.observedElapsedSeconds ?? 0
        }
        let output = [
            object["stderr_since_checkpoint"]?.stringValue,
            object["stdout_since_checkpoint"]?.stringValue
        ]
            .compactMap { $0 }
            .flatMap { $0.split(whereSeparator: \Character.isNewline) }
            .last
            .map { String($0.suffix(300)) }
        let isActive = status == "running"
        terminalActivity = TerminalActivityState(
            command: object["command"]?.stringValue ?? terminalActivity?.command ?? "",
            workingDirectory: object["working_directory"]?.stringValue
                ?? terminalActivity?.workingDirectory
                ?? "",
            status: status.replacingOccurrences(of: "_", with: " ").capitalized,
            startedAt: terminalActivity?.startedAt ?? .now.addingTimeInterval(-elapsed),
            observedElapsedSeconds: elapsed,
            latestOutput: output ?? terminalActivity?.latestOutput,
            isActive: isActive
        )
    }

    private func usageData(_ usage: ModelUsage) -> [String: Any] {
        [
            "load_duration_nanoseconds": jsonNumber(usage.loadDurationNanoseconds),
            "output_duration_nanoseconds": jsonNumber(usage.outputDurationNanoseconds),
            "output_token_count": jsonNumber(usage.outputTokenCount),
            "prompt_duration_nanoseconds": jsonNumber(usage.promptDurationNanoseconds),
            "prompt_token_count": jsonNumber(usage.promptTokenCount),
            "total_duration_nanoseconds": jsonNumber(usage.totalDurationNanoseconds)
        ]
    }

    private func jsonNumber<T: BinaryInteger>(_ value: T?) -> Any {
        value.map { NSNumber(value: Int64($0)) } ?? NSNull()
    }

    private func jsonNumber(_ value: Double?) -> Any {
        value.map(NSNumber.init(value:)) ?? NSNull()
    }

    private func toolCallData(
        _ call: ToolCall,
        documentPrivacyMode: Bool
    ) -> [String: Any] {
        [
            "arguments": jsonObject(.object(ToolTranscriptContent.safeArguments(
                name: call.function.name,
                arguments: call.function.arguments,
                documentPrivacyMode: documentPrivacyMode
            ))),
            "name": call.function.name,
            "type": call.type
        ]
    }

    private func jsonObject(_ value: JSONValue) -> Any {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data)
        else {
            return [:]
        }
        return object
    }

    private func encodedJSON(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let object = try? JSONSerialization.jsonObject(with: data),
              let prettyData = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
              )
        else {
            return "{}"
        }
        return String(decoding: prettyData, as: UTF8.self)
    }

    private func warmSelectedModel() async {
        let model = ollama.selectedModel
        guard ollama.state.isReady, !model.isEmpty else { return }
        warmupState = "Preparing model and stable prompt prefix"
        do {
            let metrics = try await agent.warmUp(model: model) { [weak self] event in
                await self?.recordWarmupTrace(event)
            }
            guard ollama.selectedModel == model else { return }
            warmupElapsedSeconds = metrics.elapsedSeconds
            warmupPrefixTokens = metrics.prefixPromptTokenCount
            warmupState = "Ready"
        } catch {
            guard ollama.selectedModel == model else { return }
            warmupState = "Failed: \(error.localizedDescription)"
            await log.record("chat.warmup.unavailable", fields: [
                "error": String(describing: error),
                "model": model
            ])
        }
    }

    private func recordWarmupTrace(_ event: ModelTraceEvent) {
        if let id = activeGenerationConversationID,
           let conversation = conversations.first(where: { $0.id == id }) {
            let assistant = conversation.messages.first { $0.id == currentAssistantID }
            try? modelTraceTranscript.consume(event, in: conversation, before: assistant)
            transcriptRevision += 1
        } else {
            warmupTraceEvents.append(event)
        }
    }

    static func modelHistory(for conversation: ConversationRecord) -> [ChatMessage] {
        conversation.messages
            .sorted { $0.sequence < $1.sequence }
            .compactMap { message in
                guard message.status == .complete else { return nil }
                switch message.role {
                case .user:
                    return ChatMessage(
                        role: .user,
                        content: AttachmentModelContentBuilder.content(for: message)
                    )
                case .assistant:
                    return ChatMessage(role: .assistant, content: message.content)
                case .thinking, .tool, .modelInput, .toolCall, .toolResult, .modelOutput:
                    return nil
                }
            }
    }

    private func reloadConversations(preservingSelection: Bool = false) {
        let selectedID = preservingSelection ? selectedConversation?.id : nil
        do {
            conversations = try database.conversations()
            if let selectedID {
                selectedConversation = conversations.first { $0.id == selectedID }
            } else if selectedConversation == nil {
                selectedConversation = conversations.first
            }
        } catch {
            activity = error.localizedDescription
        }
    }

    private func reconcileArtifacts() async {
        do {
            let referencedPaths = try database.referencedArtifactPaths()
            _ = try await artifactStore.reconcile(referencedRelativePaths: referencedPaths)
            try database.removeUnreferencedArtifactBlobs()
        } catch {
            await log.record("artifacts.reconciliation_failed", fields: [
                "error": String(describing: error)
            ])
        }
    }
}

struct TerminalActivityState: Equatable {
    var command: String
    var workingDirectory: String
    var status: String
    var startedAt: Date
    var observedElapsedSeconds: Double
    var latestOutput: String?
    var isActive: Bool

    func elapsedSeconds(at date: Date) -> Double {
        isActive
            ? max(observedElapsedSeconds, date.timeIntervalSince(startedAt))
            : observedElapsedSeconds
    }
}

nonisolated enum DocumentConversationPolicy {
    static let localDocumentReferenceMarker = "privateai.local_document_reference"

    static func hasDocumentToolHistory(toolNames: [String]) -> Bool {
        !Set(toolNames).isDisjoint(with: [
            "document_analysis", "local_resources", localDocumentReferenceMarker
        ])
    }
}