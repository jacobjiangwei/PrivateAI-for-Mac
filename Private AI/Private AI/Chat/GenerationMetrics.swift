import Foundation
import LLMCore

struct GenerationMetrics: Equatable {
    private(set) var startedAt: Date?
    private(set) var firstTextAt: Date?
    private(set) var firstOutputAt: Date?
    private(set) var thinkingCharacterCount = 0
    private(set) var receivedChunkCount = 0
    private(set) var outputTokenCount = 0
    private(set) var promptTokenCount = 0
    private(set) var promptSeconds: Double = 0
    private(set) var loadSeconds: Double = 0
    private(set) var completedRequestCount = 0
    private(set) var hasLoadDuration = false
    private(set) var hasPromptDuration = false
    private(set) var requestCount = 0
    private(set) var requestBytes = 0
    private(set) var toolSchemaBytes = 0
    private var outputSeconds: Double = 0
    private(set) var streamedCharacterCount = 0
    private(set) var ttftSeconds: Double?
    private(set) var liveTokensPerSecond: Double?
    private(set) var finalTokensPerSecond: Double?
    private(set) var endedAt: Date?
    private var recentChunks: [Date] = []

    var firstAnswerSeconds: Double? {
        guard let startedAt, let firstTextAt else { return nil }
        return max(0, firstTextAt.timeIntervalSince(startedAt))
    }

    func elapsedToFirstOutput(at date: Date) -> Double? {
        guard let startedAt else { return nil }
        return ttftSeconds ?? max(0, (endedAt ?? date).timeIntervalSince(startedAt))
    }

    func estimatedTokensPerSecond(at date: Date) -> Double? {
        guard let firstOutputAt else { return nil }
        let end = endedAt ?? date
        let recent = recentChunks.filter { end.timeIntervalSince($0) <= 2 }
        return Double(recent.count) / max(0.25, min(2, end.timeIntervalSince(firstOutputAt)))
    }

    mutating func recordRequest(_ trace: ModelRequestTrace) {
        guard !trace.purpose.isWarmup else { return }
        requestCount += 1
        requestBytes = trace.byteCount
        toolSchemaBytes = trace.toolSchemaByteCount
    }

    mutating func start(at date: Date = Date()) {
        self = GenerationMetrics(startedAt: date)
    }

    mutating func recordText(_ text: String, at date: Date = Date(), isAnswer: Bool = true) {
        guard startedAt != nil, !text.isEmpty else { return }
        if isAnswer, firstTextAt == nil {
            firstTextAt = date
        }
        streamedCharacterCount += text.count
        recordOutput(at: date)
    }

    mutating func recordThinking(_ text: String, at date: Date = Date()) {
        guard startedAt != nil, !text.isEmpty else { return }
        thinkingCharacterCount += text.count
        recordOutput(at: date)
    }

    private mutating func recordOutput(at date: Date) {
        guard let startedAt else { return }
        if firstOutputAt == nil {
            firstOutputAt = date
            ttftSeconds = max(0, date.timeIntervalSince(startedAt))
        }
        receivedChunkCount += 1
        recentChunks.removeAll { date.timeIntervalSince($0) > 2 }
        recentChunks.append(date)
        liveTokensPerSecond = estimatedTokensPerSecond(at: date)
    }

    mutating func recordUsage(_ usage: ModelUsage) {
        completedRequestCount += 1
        hasLoadDuration = hasLoadDuration || usage.loadDurationNanoseconds != nil
        hasPromptDuration = hasPromptDuration || usage.promptDurationNanoseconds != nil
        outputTokenCount += usage.outputTokenCount ?? 0
        promptTokenCount += usage.promptTokenCount ?? 0
        promptSeconds += Double(usage.promptDurationNanoseconds ?? 0) / 1_000_000_000
        loadSeconds += Double(usage.loadDurationNanoseconds ?? 0) / 1_000_000_000
        outputSeconds += Double(usage.outputDurationNanoseconds ?? 0) / 1_000_000_000
    }

    mutating func finish(performance: AgentPerformance) {
        endedAt = Date()
        if ttftSeconds == nil {
            ttftSeconds = performance.timeToFirstEventSeconds
        }
        let usage = performance.modelUsage.reduce(into: (tokens: 0, nanoseconds: UInt64(0))) {
            $0.tokens += $1.outputTokenCount ?? 0
            $0.nanoseconds += $1.outputDurationNanoseconds ?? 0
        }
        if outputTokenCount > 0, outputSeconds > 0 {
            finalTokensPerSecond = Double(outputTokenCount) / outputSeconds
        } else if usage.tokens > 0, usage.nanoseconds > 0 {
            outputTokenCount = usage.tokens
            finalTokensPerSecond = Double(usage.tokens) / (Double(usage.nanoseconds) / 1_000_000_000)
        }
    }

    mutating func stop(at date: Date = Date()) {
        endedAt = date
        if ttftSeconds == nil, let startedAt {
            ttftSeconds = max(0, date.timeIntervalSince(startedAt))
        }
    }
}