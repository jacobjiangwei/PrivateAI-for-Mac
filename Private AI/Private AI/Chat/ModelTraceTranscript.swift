import Foundation
import LLMCore

@MainActor
final class ModelTraceTranscript {
    private struct RequestState {
        let trace: ModelRequestTrace
        let message: MessageRecord
        var firstOutputAt: Date?
        var thinking: MessageRecord?
        var output: MessageRecord?
    }

    private let database: ConversationDatabase
    private var requests: [UUID: RequestState] = [:]

    init(database: ConversationDatabase) {
        self.database = database
    }

    func purpose(for id: UUID) -> ModelRequestTrace.Purpose? {
        requests[id]?.trace.purpose
    }

    func consume(
        _ event: ModelTraceEvent,
        in conversation: ConversationRecord,
        before assistant: MessageRecord?
    ) throws {
        switch event {
        case .request(let trace):
            let message = try database.appendMessage(
                to: conversation,
                role: .modelInput,
                content: trace.body,
                status: .streaming,
                toolName: "\(trace.purpose.label) | \(trace.createdAt.ISO8601Format(.init(includingFractionalSeconds: true))) | \(trace.endpoint) | \(trace.byteCount) B | Tools ~\(trace.toolSchemaByteCount) B"
            )
            requests[trace.id] = RequestState(trace: trace, message: message)
            if let assistant { try database.moveToEnd(assistant) }
        case .output(let id, let event, let date):
            guard var state = requests[id] else { return }
            let isCompletion: Bool
            if case .completed = event { isCompletion = true } else { isCompletion = false }
            if state.firstOutputAt == nil, !isCompletion {
                state.firstOutputAt = date
                let seconds = max(0, date.timeIntervalSince(state.trace.createdAt))
                state.message.toolName = (state.message.toolName ?? "")
                    + String(format: " | Request TTFT %.2fs", seconds)
            }
            switch event {
            case .thinking(let delta), .text(let delta):
                if case .conversation = state.trace.purpose { break }
                let isThinking: Bool
                if case .thinking = event { isThinking = true } else { isThinking = false }
                var message = isThinking ? state.thinking : state.output
                if message == nil {
                    message = try database.appendMessage(
                        to: conversation,
                        role: isThinking ? .thinking : .modelOutput,
                        content: "",
                        status: .streaming,
                        toolName: state.trace.purpose.label
                    )
                    if let assistant { try database.moveToEnd(assistant) }
                }
                if let message { database.appendStreamingContent(delta, to: message) }
                if isThinking { state.thinking = message } else { state.output = message }
            case .toolCalls:
                break
            case .completed(let usage):
                let input = usage.promptTokenCount.map(String.init) ?? "unknown"
                let output = usage.outputTokenCount.map(String.init) ?? "unknown"
                state.message.toolName = (state.message.toolName ?? "")
                    + " | Input \(input) tokens | Output \(output) tokens"
                    + " | Load \(duration(usage.loadDurationNanoseconds))"
                    + " | Prefill \(duration(usage.promptDurationNanoseconds))"
                    + " | Decode \(duration(usage.outputDurationNanoseconds))"
                try database.update(state.message, status: .complete)
                for message in [state.thinking, state.output].compactMap({ $0 }) {
                    try database.update(message, status: .complete)
                }
            }
            requests[id] = state
        case .failed(let id, let error):
            guard let state = requests[id] else { return }
            for message in [state.message, state.thinking, state.output].compactMap({ $0 }) {
                try database.update(message, status: .failed, errorMessage: error)
            }
        }
    }

    private func duration(_ nanoseconds: UInt64?) -> String {
        nanoseconds.map { String(format: "%.2fs", Double($0) / 1_000_000_000) } ?? "unknown"
    }

    func finish(in conversation: ConversationRecord, status: PersistedMessageStatus) throws {
        for state in requests.values where state.message.conversation?.id == conversation.id {
            for message in [state.message, state.thinking, state.output].compactMap({ $0 })
            where message.status == .streaming {
                try database.update(message, status: status)
            }
        }
        requests = requests.filter { $0.value.message.conversation?.id != conversation.id }
    }
}