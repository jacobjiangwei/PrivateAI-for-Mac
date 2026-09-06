import Foundation

public struct AgentConfiguration: Equatable, Sendable {
    public let model: String
    public let systemPrompt: String
    public let keepAlive: String
    public let options: ModelOptions
    public let think: Bool
    public let maximumToolRounds: Int
    public let maximumToolCallsPerRound: Int?
    public let maximumToolCallsTotal: Int?
    public let repeatedToolFailureLimit: Int
    public let maximumResponseBytes: Int
    public let automaticallyWarmsUp: Bool

    public init(
        model: String,
        keepAlive: String = "30m",
        options: ModelOptions = ModelOptions(),
        think: Bool = false,
        maximumToolRounds: Int = 8,
        maximumToolCallsPerRound: Int? = nil,
        maximumToolCallsTotal: Int? = nil,
        repeatedToolFailureLimit: Int = 3,
        maximumResponseBytes: Int = 1_048_576,
        automaticallyWarmsUp: Bool = true
    ) {
        self.model = model
        self.systemPrompt = LLMCoreSystemPrompt.current
        self.keepAlive = keepAlive
        self.options = options
        self.think = think
        self.maximumToolRounds = maximumToolRounds
        self.maximumToolCallsPerRound = maximumToolCallsPerRound
        self.maximumToolCallsTotal = maximumToolCallsTotal
        self.repeatedToolFailureLimit = repeatedToolFailureLimit
        self.maximumResponseBytes = maximumResponseBytes
        self.automaticallyWarmsUp = automaticallyWarmsUp
    }
}

public struct AgentPerformance: Equatable, Sendable {
    public let timeToFirstEventSeconds: Double?
    public let timeToFirstTextSeconds: Double?
    public let totalSeconds: Double
    public let modelRequestCount: Int
    public let toolCallCount: Int
    public let modelUsage: [ModelUsage]

    public init(
        timeToFirstEventSeconds: Double?,
        timeToFirstTextSeconds: Double?,
        totalSeconds: Double,
        modelRequestCount: Int,
        toolCallCount: Int,
        modelUsage: [ModelUsage]
    ) {
        self.timeToFirstEventSeconds = timeToFirstEventSeconds
        self.timeToFirstTextSeconds = timeToFirstTextSeconds
        self.totalSeconds = totalSeconds
        self.modelRequestCount = modelRequestCount
        self.toolCallCount = toolCallCount
        self.modelUsage = modelUsage
    }
}

public enum AgentEvent: Equatable, Sendable {
    case modelRequestStarted(round: Int)
    case modelRequestFinished(round: Int, usage: ModelUsage)
    case thinking(String)
    case text(String)
    case toolCallsProposed(round: Int, calls: [ToolCall])
    case toolStarted(name: String, arguments: [String: JSONValue])
    case toolProgress(name: String, detail: String)
    case toolFinished(ToolExecution)
    case contextTrimmed(droppedMessages: Int, approximateBytesBefore: Int, approximateBytesAfter: Int)
}

public struct AgentResult: Equatable, Sendable {
    public let text: String
    public let messages: [ChatMessage]
    public let performance: AgentPerformance

    public init(text: String, messages: [ChatMessage], performance: AgentPerformance) {
        self.text = text
        self.messages = messages
        self.performance = performance
    }
}

public enum AgentRuntimeError: Error, Equatable, LocalizedError, Sendable {
    case emptyPrompt
    case toolRoundLimitExceeded(Int)
    case toolCallLimitExceeded(perRound: Int?, total: Int?)
    case exclusiveToolCallConflict(String)
    case repeatedToolFailure(name: String, attempts: Int)
    case responseTooLarge(Int)
    case requiredContextTooLarge(required: Int, budget: Int)
    case emptyFinalResponse
    case incompleteFinalResponse
    case streamEndedWithoutCompletion

    public var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            "The prompt must not be empty."
        case .toolRoundLimitExceeded(let limit):
            "The model exceeded the limit of \(limit) tool rounds."
        case .toolCallLimitExceeded(let perRound, let total):
            switch (perRound, total) {
            case (.some(let perRound), .some(let total)):
                "The model exceeded the configured tool-call budget (\(perRound) per round, \(total) total)."
            case (.some(let perRound), .none):
                "The model exceeded the configured limit of \(perRound) tool calls per round."
            case (.none, .some(let total)):
                "The model exceeded the configured limit of \(total) tool calls per run."
            case (.none, .none):
                "The model exceeded the configured tool-call budget."
            }
        case .exclusiveToolCallConflict(let name):
            "Tool '\(name)' must be the only tool call in its model round."
        case .repeatedToolFailure(let name, let attempts):
            "Tool '\(name)' failed with identical arguments \(attempts) times."
        case .responseTooLarge(let limit):
            "The model response exceeded the \(limit)-byte limit."
        case .requiredContextTooLarge(let required, let budget):
            "The required system prompt, current task, and latest Tool evidence need approximately \(required) bytes, exceeding the \(budget)-byte context budget."
        case .emptyFinalResponse:
            "The model did not produce a user-visible final answer after one tool-free correction."
        case .incompleteFinalResponse:
            "The model's user-visible final answer was truncated after one tool-free correction."
        case .streamEndedWithoutCompletion:
            "The model stream ended without a completion event."
        }
    }
}

public actor AgentRuntime {
    public typealias EventHandler = @Sendable (AgentEvent) async -> Void

    private let provider: any ModelProvider
    private let toolRuntime: ToolRuntime
    private let configuration: AgentConfiguration
    private var warmupTask: Task<WarmupMetrics, any Error>?

    public init(
        provider: any ModelProvider,
        toolRuntime: ToolRuntime,
        configuration: AgentConfiguration
    ) {
        self.provider = provider
        self.toolRuntime = toolRuntime
        self.configuration = configuration
    }

    public func warmUp() async throws -> WarmupMetrics {
        if let warmupTask {
            return try await warmupTask.value
        }
        let task = Task { [provider, toolRuntime, configuration] in
            let clock = ContinuousClock()
            let start = clock.now
            let modelWarmup = try await provider.warmUp(
                model: configuration.model,
                keepAlive: configuration.keepAlive,
                options: configuration.options
            )
            let toolDefinitions = await toolRuntime.definitions
            let prefixUsage = try await Self.prewarmStablePrefix(
                provider: provider,
                configuration: configuration,
                toolDefinitions: toolDefinitions
            )
            return WarmupMetrics(
                elapsedSeconds: elapsedSeconds(since: start, clock: clock),
                providerLoadSeconds: modelWarmup.providerLoadSeconds,
                prefixPromptTokenCount: prefixUsage.promptTokenCount,
                prefixPromptSeconds: prefixUsage.promptDurationNanoseconds.map {
                    Double($0) / 1_000_000_000
                }
            )
        }
        warmupTask = task
        do {
            return try await task.value
        } catch {
            warmupTask = nil
            throw error
        }
    }

    public func cancelActiveTools() async {
        await toolRuntime.cancelAll()
    }

    private static func prewarmStablePrefix(
        provider: any ModelProvider,
        configuration: AgentConfiguration,
        toolDefinitions: [ToolDefinition]
    ) async throws -> ModelUsage {
        let request = ModelRequest(
            model: configuration.model,
            messages: [
                ChatMessage(role: .system, content: configuration.systemPrompt),
                ChatMessage(
                    role: .user,
                    content: "Initialize the stable instruction prefix. Do not call tools."
                )
            ],
            tools: toolDefinitions,
            think: false,
            keepAlive: configuration.keepAlive,
            options: ModelOptions(
                numContext: configuration.options.numContext,
                temperature: configuration.options.temperature,
                numPredict: 1
            )
        )
        let stream = try await provider.stream(request)
        var usage: ModelUsage?

        for try await event in stream {
            try Task.checkCancellation()
            if case .completed(let completedUsage) = event {
                usage = completedUsage
            }
        }

        guard let usage else {
            throw AgentRuntimeError.streamEndedWithoutCompletion
        }
        return usage
    }

    public func run(
        prompt: String,
        history: [ChatMessage] = [],
        onEvent: @escaping EventHandler = { _ in }
    ) async throws -> AgentResult {
        do {
            return try await runLoop(
                prompt: prompt,
                history: history,
                onEvent: onEvent
            )
        } catch {
            await toolRuntime.cancelAll()
            throw error
        }
    }

    private func runLoop(
        prompt: String,
        history: [ChatMessage],
        onEvent: @escaping EventHandler
    ) async throws -> AgentResult {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw AgentRuntimeError.emptyPrompt
        }
        if configuration.automaticallyWarmsUp {
            _ = try await warmUp()
        }

        let clock = ContinuousClock()
        let start = clock.now
        var firstEventSeconds: Double?
        var firstTextSeconds: Double?
        var modelRequestCount = 0
        var toolCallCount = 0
        var toolCallBudgetUsed = 0
        var failedCallCounts: [String: Int] = [:]
        var usages: [ModelUsage] = []
        var forceToolFreeFinalization = false
        var toolCallBudgetExhausted = false
        var finalizationReminderAdded = false
        var finalizationCorrectionUsed = false
        var finalResponseCorrectionUsed = false
        var forceThinkingDisabled = false
        var failedArgumentsByTool: [String: [[String: JSONValue]]] = [:]
        var successfulExecutionsByReuseKey: [ToolReuseKey: ToolExecution] = [:]
        var messages = [ChatMessage(role: .system, content: configuration.systemPrompt)]
        messages.append(contentsOf: history.filter { $0.role != .system })
        let currentUserIndex = messages.count
        messages.append(ChatMessage(role: .user, content: trimmedPrompt))
        let toolDefinitions = await toolRuntime.definitions

        for round in 0...(configuration.maximumToolRounds + 3) {
            try Task.checkCancellation()
            let shouldFinalizeWithoutTools = forceToolFreeFinalization
                || round >= configuration.maximumToolRounds
            if shouldFinalizeWithoutTools, !finalizationReminderAdded {
                let instruction = toolCallBudgetExhausted
                    ? toolBudgetFinalizationInstruction
                    : toolRoundFinalizationInstruction
                messages[currentUserIndex] = ChatMessage(
                    role: .user,
                    content: trimmedPrompt + "\n\n" + instruction
                )
                finalizationReminderAdded = true
            }
            modelRequestCount += 1
            await onEvent(.modelRequestStarted(round: round))

            let projectedMessages = retainingOnlyLatestToolImages(messages)
            // Vision inputs are budgeted separately from their encoded bytes. Keep one
            // frame while still reserving room for the configured final response.
            let inputFraction = projectedMessages.contains { !$0.images.isEmpty }
                ? 0.72
                : 0.6
            let contextBudgetBytes = Int(
                Double(configuration.options.numContext) * 3.0 * inputFraction
            )
            let trim = trimMessagesToBudget(projectedMessages, budgetBytes: contextBudgetBytes)
            if trim.requiredBytesExceededBudget {
                throw AgentRuntimeError.requiredContextTooLarge(
                    required: trim.requiredBytes,
                    budget: contextBudgetBytes
                )
            }
            if trim.didTrim {
                await onEvent(.contextTrimmed(
                    droppedMessages: trim.droppedCount,
                    approximateBytesBefore: trim.bytesBefore,
                    approximateBytesAfter: trim.bytesAfter
                ))
            }

            let request = ModelRequest(
                model: configuration.model,
                messages: trim.messages,
                tools: shouldFinalizeWithoutTools ? [] : toolDefinitions,
                think: configuration.think && !forceThinkingDisabled,
                keepAlive: configuration.keepAlive,
                options: configuration.options
            )

            let stream = try await provider.stream(request)
            var responseText = ""
            var responseThinking = ""
            var proposedCalls: [ToolCall] = []
            var completed = false
            var completionUsage: ModelUsage?

            for try await event in stream {
                try Task.checkCancellation()
                if firstEventSeconds == nil {
                    firstEventSeconds = elapsedSeconds(since: start, clock: clock)
                }

                switch event {
                case .text(let text):
                    if firstTextSeconds == nil {
                        firstTextSeconds = elapsedSeconds(since: start, clock: clock)
                    }
                    responseText += text
                    guard responseText.lengthOfBytes(using: .utf8) <= configuration.maximumResponseBytes else {
                        throw AgentRuntimeError.responseTooLarge(configuration.maximumResponseBytes)
                    }
                    await onEvent(.text(text))
                case .thinking(let thinking):
                    responseThinking += thinking
                    await onEvent(.thinking(thinking))
                case .toolCalls(let calls):
                    proposedCalls.append(contentsOf: calls)
                    await onEvent(.toolCallsProposed(round: round, calls: calls))
                case .completed(let usage):
                    usages.append(usage)
                    completionUsage = usage
                    completed = true
                    await onEvent(.modelRequestFinished(round: round, usage: usage))
                }
            }

            guard completed else {
                throw AgentRuntimeError.streamEndedWithoutCompletion
            }

            guard !proposedCalls.isEmpty else {
                messages.append(ChatMessage(
                    role: .assistant,
                    content: responseText,
                    thinking: responseThinking.isEmpty ? nil : responseThinking
                ))
                let isEmptyFinalResponse = responseText
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty
                let isTruncatedFinalResponse = completionUsage?.finishReason == "length"
                    || (
                        configuration.options.numPredict != nil
                            && completionUsage?.outputTokenCount
                                == configuration.options.numPredict
                    )
                if isEmptyFinalResponse || isTruncatedFinalResponse {
                    guard !finalResponseCorrectionUsed else {
                        throw isEmptyFinalResponse
                            ? AgentRuntimeError.emptyFinalResponse
                            : AgentRuntimeError.incompleteFinalResponse
                    }
                    messages[currentUserIndex] = ChatMessage(
                        role: .user,
                        content: trimmedPrompt + "\n\n" + finalResponseCorrectionInstruction
                    )
                    forceToolFreeFinalization = true
                    forceThinkingDisabled = true
                    finalizationReminderAdded = true
                    finalResponseCorrectionUsed = true
                    continue
                }
                await toolRuntime.cancelAll()
                try Task.checkCancellation()
                return AgentResult(
                    text: responseText,
                    messages: messages.map { $0.withoutImages() },
                    performance: AgentPerformance(
                        timeToFirstEventSeconds: firstEventSeconds,
                        timeToFirstTextSeconds: firstTextSeconds,
                        totalSeconds: elapsedSeconds(since: start, clock: clock),
                        modelRequestCount: modelRequestCount,
                        toolCallCount: toolCallCount,
                        modelUsage: usages
                    )
                )
            }

            var stabilizedCalls: [ToolCall] = []
            for call in proposedCalls {
                let name = call.function.name
                let stabilized = await toolRuntime.stabilizedCall(
                    call,
                    previousArguments: failedArgumentsByTool[name, default: []]
                )
                stabilizedCalls.append(stabilized)
            }
            proposedCalls = stabilizedCalls

            if proposedCalls.count > 1,
               let exclusiveCall = await firstExclusiveCall(in: proposedCalls) {
                proposedCalls = [exclusiveCall]
            }

            if shouldFinalizeWithoutTools {
                messages.append(ChatMessage(
                    role: .assistant,
                    content: responseText,
                    thinking: responseThinking.isEmpty ? nil : responseThinking
                ))
                guard !finalizationCorrectionUsed else {
                    if toolCallBudgetExhausted {
                        throw AgentRuntimeError.toolCallLimitExceeded(
                            perRound: configuration.maximumToolCallsPerRound,
                            total: configuration.maximumToolCallsTotal
                        )
                    }
                    throw AgentRuntimeError.toolRoundLimitExceeded(
                        configuration.maximumToolRounds
                    )
                }
                let finalizationInstruction = toolCallBudgetExhausted
                    ? toolBudgetFinalizationInstruction
                    : toolRoundFinalizationInstruction
                let correctionInstruction = toolCallBudgetExhausted
                    ? toolBudgetCorrectionInstruction
                    : toolRoundCorrectionInstruction
                messages[currentUserIndex] = ChatMessage(
                    role: .user,
                    content: trimmedPrompt
                        + "\n\n"
                        + finalizationInstruction
                        + "\n\n"
                        + correctionInstruction
                )
                forceToolFreeFinalization = true
                finalizationCorrectionUsed = true
                continue
            }

            var proposedBudgetCost = 0
            for call in proposedCalls {
                proposedBudgetCost += await toolRuntime.toolCallBudgetCost(call)
            }
            let totalBudgetAlreadyExhausted = configuration.maximumToolCallsTotal.map {
                toolCallBudgetUsed >= $0
            } ?? false
            if let maximumToolCallsPerRound = configuration.maximumToolCallsPerRound,
               proposedCalls.count > maximumToolCallsPerRound,
               !totalBudgetAlreadyExhausted {
                throw AgentRuntimeError.toolCallLimitExceeded(
                    perRound: configuration.maximumToolCallsPerRound,
                    total: configuration.maximumToolCallsTotal
                )
            }
                if let maximumToolCallsTotal = configuration.maximumToolCallsTotal,
                    toolCallBudgetUsed + proposedBudgetCost > maximumToolCallsTotal {
                messages.append(ChatMessage(
                    role: .assistant,
                    content: responseText,
                    thinking: responseThinking.isEmpty ? nil : responseThinking
                ))
                messages[currentUserIndex] = ChatMessage(
                    role: .user,
                    content: trimmedPrompt + "\n\n" + toolBudgetFinalizationInstruction
                )
                forceToolFreeFinalization = true
                toolCallBudgetExhausted = true
                finalizationReminderAdded = true
                continue
            }

            messages.append(ChatMessage(
                role: .assistant,
                content: responseText,
                thinking: responseThinking.isEmpty ? nil : responseThinking,
                toolCalls: proposedCalls
            ))
            toolCallCount += proposedCalls.count
            toolCallBudgetUsed += proposedBudgetCost
            let batches = await makeToolBatches(proposedCalls)
            var reuseKeyCounts: [ToolReuseKey: Int] = [:]
            for call in proposedCalls {
                if let scope = await toolRuntime.successfulResultReuseKey(call) {
                    let key = ToolReuseKey(toolName: call.function.name, scope: scope)
                    reuseKeyCounts[key, default: 0] += 1
                }
            }
            let ambiguousReuseKeys = Set(reuseKeyCounts.compactMap {
                $0.value > 1 ? $0.key : nil
            })
            for key in ambiguousReuseKeys {
                successfulExecutionsByReuseKey[key] = nil
            }
            let reusableExecutions = successfulExecutionsByReuseKey
            var roundExecutions: [ToolExecution] = []

            for batch in batches {
                try Task.checkCancellation()
                var reuseKeysByIndex: [Int: ToolReuseKey] = [:]
                var reusedExecutionsByIndex: [Int: ToolExecution] = [:]
                for item in batch.items {
                    if let scope = await toolRuntime.successfulResultReuseKey(item.call) {
                        let key = ToolReuseKey(
                            toolName: item.call.function.name,
                            scope: scope
                        )
                        reuseKeysByIndex[item.index] = key
                                if !ambiguousReuseKeys.contains(key),
                                    let previous = reusableExecutions[key] {
                            reusedExecutionsByIndex[item.index] = ToolExecution(
                                name: item.call.function.name,
                                arguments: item.call.function.arguments,
                                content: previous.content,
                                succeeded: true,
                                images: previous.images
                            )
                        }
                    }
                    await onEvent(
                        .toolStarted(
                            name: item.call.function.name,
                            arguments: item.call.function.arguments
                        )
                    )
                    if reusedExecutionsByIndex[item.index] != nil {
                        await onEvent(.toolProgress(
                            name: item.call.function.name,
                            detail: "Reusing the prior successful result from this run"
                        ))
                    }
                }

                let batchExecutions: [ToolExecution]
                if batch.concurrent {
                    let toolRuntime = self.toolRuntime
                    batchExecutions = await withTaskGroup(
                        of: (Int, ToolExecution).self,
                        returning: [ToolExecution].self
                    ) { group in
                        for item in batch.items
                        where reusedExecutionsByIndex[item.index] == nil {
                            group.addTask {
                                (item.index, await toolRuntime.execute(item.call))
                            }
                        }

                        var indexedExecutions = reusedExecutionsByIndex.map {
                            ($0.key, $0.value)
                        }
                        for await execution in group {
                            indexedExecutions.append(execution)
                        }
                        return indexedExecutions
                            .sorted { $0.0 < $1.0 }
                            .map(\.1)
                    }
                } else if let item = batch.items.first {
                    if let reused = reusedExecutionsByIndex[item.index] {
                        batchExecutions = [reused]
                    } else {
                        batchExecutions = [await toolRuntime.execute(item.call)]
                    }
                } else {
                    batchExecutions = []
                }
                try Task.checkCancellation()
                for (item, execution) in zip(batch.items, batchExecutions) {
                    await onEvent(.toolFinished(execution))
                    let signature = toolCallSignature(item.call)
                    let canonical = await toolRuntime.canonicalArgumentsForStabilization(
                        item.call
                    )
                    if execution.succeeded {
                        failedCallCounts[signature] = nil
                        if let reuseKey = reuseKeysByIndex[item.index],
                           !ambiguousReuseKeys.contains(reuseKey) {
                            successfulExecutionsByReuseKey[reuseKey] = execution
                        }
                        if let canonical {
                            failedArgumentsByTool[item.call.function.name]?.removeAll {
                                $0 == canonical
                            }
                        }
                    } else {
                        if let canonical,
                           failedArgumentsByTool[item.call.function.name, default: []]
                            .contains(canonical) == false {
                            failedArgumentsByTool[item.call.function.name, default: []]
                                .append(canonical)
                        }
                        let attempts = failedCallCounts[signature, default: 0] + 1
                        failedCallCounts[signature] = attempts
                        if attempts >= configuration.repeatedToolFailureLimit {
                            throw AgentRuntimeError.repeatedToolFailure(
                                name: execution.name,
                                attempts: attempts
                            )
                        }
                    }
                }
                roundExecutions.append(contentsOf: batchExecutions)
            }

            let boundedExecutions = boundToolBatchForContext(
                roundExecutions,
                messages: messages,
                budgetBytes: contextBudgetBytes
            )

            for execution in boundedExecutions {
                if !execution.images.isEmpty {
                    messages = messages.map { message in
                        message.role == .tool && !message.images.isEmpty
                            ? message.withoutImages()
                            : message
                    }
                }
                messages.append(
                    ChatMessage(
                        role: .tool,
                        content: execution.content,
                        toolName: execution.name,
                        images: execution.images
                    )
                )
            }
        }

        throw AgentRuntimeError.toolRoundLimitExceeded(configuration.maximumToolRounds)
    }

    private func makeToolBatches(_ calls: [ToolCall]) async -> [ToolBatch] {
        var batches: [ToolBatch] = []

        for (index, call) in calls.enumerated() {
            let item = IndexedToolCall(index: index, call: call)
            let concurrencySafe = await toolRuntime.isConcurrencySafe(call)
            let signature = toolCallSignature(call)
            if concurrencySafe,
               batches.last?.concurrent == true,
               batches.last?.items.contains(where: {
                   toolCallSignature($0.call) == signature
               }) == false {
                batches[batches.count - 1].items.append(item)
            } else {
                batches.append(
                    ToolBatch(concurrent: concurrencySafe, items: [item])
                )
            }
        }
        return batches
    }

    private func firstExclusiveCall(in calls: [ToolCall]) async -> ToolCall? {
        for call in calls where await toolRuntime.requiresExclusiveRound(call) {
            return call
        }
        return nil
    }
}

func boundToolBatchForContext(
    _ executions: [ToolExecution],
    messages: [ChatMessage],
    budgetBytes: Int
) -> [ToolExecution] {
    guard !executions.isEmpty else { return [] }
    var fixedIndices = Set<Int>()
    if messages.first?.role == .system { fixedIndices.insert(0) }
    if let currentUser = messages.lastIndex(where: { $0.role == .user }) {
        fixedIndices.insert(currentUser)
    }
    if let proposal = messages.lastIndex(where: {
        $0.role == .assistant && $0.toolCalls?.isEmpty == false
    }) {
        fixedIndices.insert(proposal)
    }
    let fixedBytes = fixedIndices.reduce(0) {
        $0 + approximateMessageBytes(messages[$1])
    }
    let toolEnvelopeBytes = executions.reduce(0) {
        $0 + $1.name.utf8.count + 16
    }
    let available = max(32 * executions.count, budgetBytes - fixedBytes - toolEnvelopeBytes)
    let contentSizes = executions.map { $0.content.lengthOfBytes(using: .utf8) }
    guard contentSizes.reduce(0, +) > available else { return executions }
    var limits = Array(repeating: 32, count: executions.count)
    var unresolved = Set(executions.indices)
    var remaining = available
    while !unresolved.isEmpty {
        let share = max(32, remaining / unresolved.count)
        let fitting = unresolved.filter { contentSizes[$0] <= share }
        if fitting.isEmpty {
            for index in unresolved { limits[index] = share }
            break
        }
        for index in fitting {
            limits[index] = contentSizes[index]
            remaining -= contentSizes[index]
            unresolved.remove(index)
        }
    }

    return zip(executions.indices, executions).map { index, execution in
        ToolExecution(
            name: execution.name,
            arguments: execution.arguments,
            content: ToolRuntime.boundedContent(
                execution.content,
                limitBytes: limits[index]
            ),
            succeeded: execution.succeeded,
            errorType: execution.errorType,
            images: execution.images
        )
    }
}

func retainingOnlyLatestToolImages(_ messages: [ChatMessage]) -> [ChatMessage] {
    guard let latestImageToolIndex = messages.lastIndex(where: {
        $0.role == .tool && !$0.images.isEmpty
    }) else {
        return messages
    }
    return messages.enumerated().map { index, message in
        guard message.role == .tool,
              !message.images.isEmpty,
              index != latestImageToolIndex else {
            return message
        }
        return message.withoutImages()
    }
}

private func approximateMessageBytes(_ message: ChatMessage) -> Int {
    var total = message.content.lengthOfBytes(using: .utf8)
        + message.role.rawValue.utf8.count
        + 8
    if let thinking = message.thinking {
        total += thinking.lengthOfBytes(using: .utf8)
    }
    if let toolCalls = message.toolCalls,
       let data = try? JSONEncoder().encode(toolCalls) {
        total += data.count
    }
    if let toolName = message.toolName {
        total += toolName.utf8.count
    }
    for image in message.images {
        if let width = image.width, let height = image.height {
            total += max(1_024, width * height / 256)
        } else {
            total += 4_096
        }
    }
    return total
}

private let toolBudgetFinalizationInstruction = """
The tool-call budget for this run is exhausted. Do not call any tool. Answer the user's request now using only the evidence already gathered. Be explicit about any material limitation caused by incomplete evidence.
"""

private let toolBudgetCorrectionInstruction = """
The previous tool proposal could not be executed because the tool-call budget is exhausted. Do not propose or mention another tool call. Produce the best final answer now from the evidence already available, and state any important coverage limitation.
"""

private let toolRoundFinalizationInstruction = """
The tool-execution round limit for this run has been reached. Do not call any tool. Answer the user's request now using only the evidence already gathered. Be explicit about any material limitation caused by incomplete evidence.
"""

private let toolRoundCorrectionInstruction = """
The previous tool proposal could not be executed because the tool-execution round limit has been reached. Do not propose or mention another tool call. Produce the best final answer now from the evidence already available, and state any important coverage limitation.
"""

private let finalResponseCorrectionInstruction = """
The previous model response did not produce a complete user-visible final answer. Do not call any tool and do not repeat intermediate work. Using only the tool evidence and reasoning already present in this run, produce a concise complete final answer now. Prioritize every explicit output requirement from the user. Do not output analysis or thinking.
"""

private struct IndexedToolCall: Sendable {
    let index: Int
    let call: ToolCall
}

private struct ToolBatch: Sendable {
    let concurrent: Bool
    var items: [IndexedToolCall]
}

private struct ToolReuseKey: Hashable, Sendable {
    let toolName: String
    let scope: String
}

private func elapsedSeconds(since start: ContinuousClock.Instant, clock: ContinuousClock) -> Double {
    let components = start.duration(to: clock.now).components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}

private func toolCallSignature(_ call: ToolCall) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let value = JSONValue.object([
        "name": .string(call.function.name),
        "arguments": .object(call.function.arguments)
    ])
    guard let data = try? encoder.encode(value) else {
        return call.function.name
    }
    return String(decoding: data, as: UTF8.self)
}

struct ContextTrimResult: Equatable {
    let messages: [ChatMessage]
    let droppedCount: Int
    let bytesBefore: Int
    let bytesAfter: Int
    let requiredBytes: Int
    let requiredBytesExceededBudget: Bool
    var didTrim: Bool { droppedCount > 0 }
}

/// Keeps the request within the context budget while guaranteeing the system prompt
/// and current user query are never dropped, so the model always sees the active task.
/// Older middle messages (tool results, earlier turns) are removed first, newest kept.
func trimMessagesToBudget(_ messages: [ChatMessage], budgetBytes: Int) -> ContextTrimResult {
    func bytes(_ message: ChatMessage) -> Int { approximateMessageBytes(message) }

    let bytesBefore = messages.reduce(0) { $0 + bytes($1) }
    guard bytesBefore > budgetBytes else {
        return ContextTrimResult(
            messages: messages,
            droppedCount: 0,
            bytesBefore: bytesBefore,
            bytesAfter: bytesBefore,
            requiredBytes: 0,
            requiredBytesExceededBudget: false
        )
    }

    // Protected: system prompt (if first) and the last user message — the current task.
    var protectedIndices = Set<Int>()
    if let first = messages.first, first.role == .system {
        protectedIndices.insert(0)
    }
    if let currentUser = messages.lastIndex(where: { $0.role == .user }) {
        protectedIndices.insert(currentUser)
    }

    let groups = messageGroups(messages)
    var protectedGroups = groups.filter { group in
        !group.indices.isDisjoint(with: protectedIndices)
    }
    if messages.last?.role == .tool,
       let latestToolGroup = groups.last(where: {
           $0.indices.contains(messages.count - 1)
       }) {
        protectedGroups.append(latestToolGroup)
    }
    var kept = Set(protectedGroups.flatMap(\.indices))
    let requiredBytes = kept.reduce(0) { $0 + bytes(messages[$1]) }
    var used = requiredBytes

    // Add newest complete turns first. Tool proposals and their results are indivisible.
    for group in groups.reversed()
        where group.indices.isDisjoint(with: kept) {
        let cost = group.indices.reduce(0) { $0 + bytes(messages[$1]) }
        if used + cost <= budgetBytes {
            kept.formUnion(group.indices)
            used += cost
        }
    }

    let trimmed = messages.enumerated()
        .filter { kept.contains($0.offset) }
        .map(\.element)
    let bytesAfter = trimmed.reduce(0) { $0 + bytes($1) }

    return ContextTrimResult(
        messages: trimmed,
        droppedCount: messages.count - trimmed.count,
        bytesBefore: bytesBefore,
        bytesAfter: bytesAfter,
        requiredBytes: requiredBytes,
        requiredBytesExceededBudget: requiredBytes > budgetBytes
    )
}

private struct ContextMessageGroup {
    let indices: Set<Int>
}

private func messageGroups(_ messages: [ChatMessage]) -> [ContextMessageGroup] {
    var groups: [ContextMessageGroup] = []
    var index = 0
    while index < messages.count {
        let message = messages[index]
        if message.role == .assistant, let calls = message.toolCalls, !calls.isEmpty {
            var indices: Set<Int> = [index]
            var next = index + 1
            var remainingResults = calls.count
            while next < messages.count,
                  remainingResults > 0,
                  messages[next].role == .tool {
                indices.insert(next)
                next += 1
                remainingResults -= 1
            }
            groups.append(ContextMessageGroup(indices: indices))
            index = next
        } else {
            groups.append(ContextMessageGroup(indices: [index]))
            index += 1
        }
    }
    return groups
}